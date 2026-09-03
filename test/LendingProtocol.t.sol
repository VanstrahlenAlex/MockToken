// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "../src/MockToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LendingProtocolTest is Test {
    LendingProtocol internal protocol;
    MockToken internal collateralToken;
    MockToken internal debtToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liquidityProvider = makeAddr("liquidityProvider");

    uint256 internal constant COLLATERAL_FACTOR = 8000; // 80%
    uint256 internal constant SUPPLY_RATE = 1000; // 10% APY
    uint256 internal constant BORROW_RATE = 2000; // 20% APY

    function setUp() public {
        collateralToken = new MockToken("Collateral Token", "COLL", 18, 0);
        debtToken = new MockToken("Debt Token", "DEBT", 18, 0);
        protocol = new LendingProtocol();

        protocol.addMarket(address(collateralToken), COLLATERAL_FACTOR, SUPPLY_RATE, BORROW_RATE);
        protocol.addMarket(address(debtToken), COLLATERAL_FACTOR, SUPPLY_RATE, BORROW_RATE);

        collateralToken.mint(alice, 10_000e18);
        collateralToken.mint(bob, 10_000e18);
        debtToken.mint(liquidityProvider, 10_000e18);
        debtToken.mint(carol, 10_000e18);

        vm.prank(alice);
        collateralToken.approve(address(protocol), type(uint256).max);
        vm.prank(bob);
        collateralToken.approve(address(protocol), type(uint256).max);
        vm.prank(bob);
        debtToken.approve(address(protocol), type(uint256).max);
        vm.prank(liquidityProvider);
        debtToken.approve(address(protocol), type(uint256).max);
        vm.prank(carol);
        debtToken.approve(address(protocol), type(uint256).max);

        // Seed the debt market so borrow() has liquidity to draw from
        vm.prank(liquidityProvider);
        protocol.deposit(address(debtToken), 5_000e18);
    }

    // ---------- deposit ----------

    function test_Deposit() public {
        vm.prank(alice);
        protocol.deposit(address(collateralToken), 1_000e18);

        assertEq(protocol.userDeposits(alice, address(collateralToken)), 1_000e18);
        (uint256 totalDeposited,,, bool isActive) = protocol.users(alice);
        assertEq(totalDeposited, 1_000e18);
        assertTrue(isActive);
        assertEq(collateralToken.balanceOf(address(protocol)), 1_000e18);
    }

    function test_RevertWhen_DepositZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("Amount must be greater than 0");
        protocol.deposit(address(collateralToken), 0);
    }

    // ---------- withdraw ----------

    function test_Withdraw() public {
        vm.startPrank(alice);
        protocol.deposit(address(collateralToken), 1_000e18);
        protocol.withdraw(address(collateralToken), 400e18);
        vm.stopPrank();

        assertEq(protocol.userDeposits(alice, address(collateralToken)), 600e18);
        assertEq(collateralToken.balanceOf(alice), 10_000e18 - 600e18);
    }

    function test_RevertWhen_WithdrawMoreThanDeposited() public {
        vm.startPrank(alice);
        protocol.deposit(address(collateralToken), 100e18);
        vm.expectRevert("Insufficient deposit balance");
        protocol.withdraw(address(collateralToken), 200e18);
        vm.stopPrank();
    }

    // ---------- borrow ----------

    function test_BorrowAgainstCollateral() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18); // collateral value = 800e18
        protocol.borrow(address(debtToken), 500e18); // ratio 800/500 = 160% >= 80%
        vm.stopPrank();

        assertEq(protocol.userBorrows(bob, address(debtToken)), 500e18);
        assertEq(debtToken.balanceOf(bob), 500e18);
    }

    function test_RevertWhen_BorrowViolatesHealthFactor() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18); // collateral value = 800e18
        vm.expectRevert("Borrow would violate health factor");
        protocol.borrow(address(debtToken), 1_001e18); // ratio 800/1001 < 80%
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientLiquidity() public {
        collateralToken.mint(bob, 1_000_000e18);

        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000_000e18); // plenty of collateral
        vm.expectRevert("Insufficient liquidity");
        protocol.borrow(address(debtToken), 6_000e18); // only 5_000e18 was seeded
        vm.stopPrank();
    }

    // ---------- repay ----------

    function test_Repay() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18);
        protocol.borrow(address(debtToken), 500e18);
        protocol.repay(address(debtToken), 200e18);
        vm.stopPrank();

        assertEq(protocol.userBorrows(bob, address(debtToken)), 300e18);
    }

    // ---------- liquidate ----------

    function test_Liquidate() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18); // value 800e18
        protocol.borrow(address(debtToken), 700e18); // ratio 800/700 = 114%, healthy
        vm.stopPrank();

        assertFalse(protocol.isLiquidatable(bob));

        // Owner lowers the collateral factor, making bob's position unsafe:
        // new collateral value = 1000 * 40% = 400e18, ratio 400/700 = 57% < 80%
        protocol.updateMarket(address(collateralToken), 4000, SUPPLY_RATE, BORROW_RATE);
        assertTrue(protocol.isLiquidatable(bob));

        uint256 carolDebtBefore = debtToken.balanceOf(carol);
        uint256 carolCollateralBefore = collateralToken.balanceOf(carol);

        vm.prank(carol);
        protocol.liquidate(bob, address(debtToken), 200e18);

        // Bonus collateral seized = 200e18 * 105% = 210e18
        assertEq(protocol.userBorrows(bob, address(debtToken)), 500e18);
        assertEq(protocol.userDeposits(bob, address(collateralToken)), 1_000e18 - 210e18);
        assertEq(debtToken.balanceOf(carol), carolDebtBefore - 200e18);
        assertEq(collateralToken.balanceOf(carol), carolCollateralBefore + 210e18);
    }

    function test_RevertWhen_LiquidatingHealthyPosition() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18);
        protocol.borrow(address(debtToken), 500e18);
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert("User is not liquidatable");
        protocol.liquidate(bob, address(debtToken), 100e18);
    }

    function test_RevertWhen_SelfLiquidate() public {
        vm.prank(bob);
        vm.expectRevert("Cannot liquidate yourself");
        protocol.liquidate(bob, address(debtToken), 100e18);
    }

    // ---------- interest accrual ----------

    function test_AccrueSupplyInterest() public {
        vm.prank(alice);
        protocol.deposit(address(collateralToken), 1_000e18);

        vm.warp(block.timestamp + 365 days);
        protocol.accrueInterest(alice);

        // 10% APY over exactly 365 days => +100e18
        assertEq(protocol.userDeposits(alice, address(collateralToken)), 1_100e18);
    }

    function test_AccrueBorrowInterest() public {
        vm.startPrank(bob);
        protocol.deposit(address(collateralToken), 1_000e18);
        protocol.borrow(address(debtToken), 500e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        protocol.accrueInterest(bob);

        // 20% APY over exactly 365 days => +100e18
        assertEq(protocol.userBorrows(bob, address(debtToken)), 600e18);
    }

    // ---------- gasless deposit via signature ----------

    function test_DepositWithSignature() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        collateralToken.mint(signer, 1_000e18);
        vm.prank(signer);
        collateralToken.approve(address(protocol), type(uint256).max);

        uint256 nonce = protocol.userNonces(signer);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 amount = 300e18;

        LendingProtocol.SignatureData memory sigData =
            _signDeposit(signerPk, signer, address(collateralToken), amount, nonce, deadline);

        // A relayer (carol) submits the tx and pays gas on behalf of `signer`
        vm.prank(carol);
        protocol.depositWithSignature(signer, address(collateralToken), amount, sigData);

        assertEq(protocol.userDeposits(signer, address(collateralToken)), amount);
        assertEq(protocol.userNonces(signer), nonce + 1);
        assertEq(collateralToken.balanceOf(signer), 1_000e18 - amount);
    }

    function test_RevertWhen_SignatureExpired() public {
        uint256 signerPk = 0xA11CE;
        address signer = vm.addr(signerPk);
        collateralToken.mint(signer, 100e18);
        vm.prank(signer);
        collateralToken.approve(address(protocol), type(uint256).max);

        uint256 deadline = block.timestamp;
        LendingProtocol.SignatureData memory sigData =
            _signDeposit(signerPk, signer, address(collateralToken), 50e18, protocol.userNonces(signer), deadline);

        vm.warp(deadline + 1);

        vm.expectRevert("Signature expired");
        protocol.depositWithSignature(signer, address(collateralToken), 50e18, sigData);
    }

    function test_RevertWhen_SignatureFromWrongSigner() public {
        uint256 signerPk = 0xA11CE;
        uint256 impostorPk = 0xBEEF;
        address signer = vm.addr(signerPk);
        collateralToken.mint(signer, 100e18);
        vm.prank(signer);
        collateralToken.approve(address(protocol), type(uint256).max);

        LendingProtocol.SignatureData memory sigData = _signDeposit(
            impostorPk, signer, address(collateralToken), 50e18, protocol.userNonces(signer), block.timestamp + 1 hours
        );

        vm.expectRevert("Invalid signature");
        protocol.depositWithSignature(signer, address(collateralToken), 50e18, sigData);
    }

    // ---------- access control ----------

    function test_RevertWhen_NonOwnerAddsMarket() public {
        MockToken newToken = new MockToken("New", "NEW", 18, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        protocol.addMarket(address(newToken), COLLATERAL_FACTOR, SUPPLY_RATE, BORROW_RATE);
    }

    function test_PauseBlocksDeposit() public {
        protocol.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protocol.deposit(address(collateralToken), 100e18);
    }

    // ---------- helpers ----------

    /// @dev Signs an EIP-191 message replicating the exact hash depositWithSignature verifies
    function _signDeposit(
        uint256 pk,
        address signer,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (LendingProtocol.SignatureData memory) {
        bytes32 messageHash =
            keccak256(abi.encode(address(protocol), block.chainid, signer, token, amount, nonce, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);

        return LendingProtocol.SignatureData({nonce: nonce, deadline: deadline, signature: abi.encodePacked(r, s, v)});
    }
}
