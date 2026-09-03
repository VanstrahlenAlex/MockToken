// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";



/**
 * @title Lending Protocol
 * @author Alexander Van strahlen
 * @dev A DeFi lending and borrowing protocol that allow users to:
 *  - Deposit tokens to earn interest
 *  - Borrow tokens against their deposited collateral 
 *  - Use off-chain signature for gasless operations
 *  - Manage collateralization ratios an liquidations 
 */
contract LendingProtocol is ReentrancyGuard, Pausable, Ownable {
    
	using SafeERC20 for IERC20;
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	struct User {
		uint256 totalDeposited; // Total amount deposited by user
		uint256 totalBorrowed; // Total amount borrowed by user
		uint256 lastUpdateTime; // Last time user's data was updated
		bool isActive; // User is active if has deposits or borrows
	}

	struct Market {
		IERC20 token;  // The token being lent/borrowed
		uint256 totalSupply; //Total amount supplied to this market
		uint256 totalBorrow; // Total amount borrowed from this market
		uint256 supplyRate; // Current supply rate (APY in basis points)
		uint256 borrowRate; // Current borrow rate (APY in basis points)
		uint256 collateralFactor; // Maximum collateral ratio (e.g. 80 for 80%) Collateral factor (0 - 10000, where 10000 = 100%)
		bool isActive; // Whether this market is active
	}

	struct SignatureData {
		uint256 nonce; // Unique nonce for signature
		uint256 deadline; // Signature expiration time
		bytes signature; // ECDSA signature
	}

	// State variables
	mapping(address => User) public users; // User data mapping
	mapping(address => mapping(address => uint256)) public userDeposits;
	mapping(address => mapping(address => uint256)) public userBorrows;
	mapping(address => Market) public markets; // Market data mapping
	mapping(address => uint256) public userNonces; // User nonce mapping

	address[] public supportedTokens;
	uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% in basis point 
	uint256 public constant LIQUIDATION_BONUS = 500; // 0.5% bonus for liquidators 
	uint256 public constant BASIS_POINT = 10000; // 100% in basis point
	

	//Events
	event MarketAdded(address indexed token, uint256 collateralFactor);
	event MarketUpdated(address indexed token, uint256 collateralFactor);
	event Deposit(address indexed user, address indexed token, uint256 amount);
	event Withdraw(address indexed user, address indexed token, uint256 amount);
	event Borrow(address indexed user, address indexed token, uint256 amount);
	event Repay(address indexed user, address indexed token, uint256 amount);
	event Liquidate(address indexed liquidator, address indexed user, address indexed token, uint256 amount);
	event RatesUpdated(address indexed token, uint256 supplyRate, uint256 borrowRate);


	//Modifiers
	modifier onlyActiveMarket(address token) {
		require(markets[token].isActive, "Market is not active");
		_; 
	}

	constructor() Ownable(msg.sender){

	}

	function addMarket(address token, uint256 collateralFactor, uint256 initialSupplyRate, uint256 initialBorrowRate) external onlyOwner {
		require(token != address(0), "Invalid token address");
		require(collateralFactor <= BASIS_POINT, "Invalid collateral factor");
		require(!markets[token].isActive, "Market already exists");

		markets[token] = Market({
			token : IERC20(token),
			totalSupply : 0,
			totalBorrow : 0, 
			supplyRate : initialSupplyRate,
			borrowRate : initialBorrowRate,
			collateralFactor : collateralFactor,
			isActive : true
		});

		supportedTokens.push(token);
		emit MarketAdded(token, collateralFactor);
	}

	function updateMarket(address token, uint256 collateralFactor, uint256 supplyRate, uint256 borrowRate) external onlyOwner onlyActiveMarket(token){
		require(collateralFactor <= BASIS_POINT, "Invalid collateral factor");

		markets[token].collateralFactor = collateralFactor;
		markets[token].supplyRate = supplyRate;
		markets[token].borrowRate = borrowRate;
		
		emit MarketUpdated(token, collateralFactor);
		emit RatesUpdated(token, supplyRate, borrowRate);
	}

	/**
	 * @dev Deosit tokens to earn interest
	 * @param token The token to deposit
	 * @param amount The amount to deposit
	 */
	function deposit(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) whenNotPaused {
		require(amount > 0, "Amount must be greater than 0");
		IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

		userDeposits[msg.sender][token] += amount;
		users[msg.sender].totalDeposited += amount;
		users[msg.sender].lastUpdateTime = block.timestamp;
		users[msg.sender].isActive = true;
		markets[token].totalSupply += amount;

		markets[token].totalSupply += amount;
		emit Deposit(msg.sender, token, amount);
	}

	/**
	 * @dev Withdraw tokens from the protocol
	 * @param token The token to withdraw
	 * @param amount The amount to withdraw
	 */

	function withdraw(address token, uint256 amount) external nonReentrant onlyActiveMarket(token) whenNotPaused {
		require(amount > 0, "Amount must be greater than 0");
		require(userDeposits[msg.sender][token] >= amount, "Insufficient deposit balance");
		require(canWithdraw(msg.sender, token, amount), "Withdrawal would violate health factor");

		userDeposits[msg.sender][token] -= amount;
		users[msg.sender].totalDeposited -= amount;
		users[msg.sender].lastUpdateTime = block.timestamp;

		if (users[msg.sender].totalDeposited == 0){
			users[msg.sender].isActive = false;
		}

		markets[token].totalSupply -= amount;
		IERC20(token).safeTransfer(msg.sender, amount);

		emit Withdraw(msg.sender, token, amount);	
	}

	function borrow(address token, uint256 amount) external nonReentrant whenNotPaused() onlyActiveMarket(token){
		require(amount > 0, "Amount must be greater than 0");
		require(markets[token].totalSupply >= amount, "Insufficient liquidity");
		require(canBorrow(msg.sender, token, amount), "Borrow would violate health factor");

		userBorrows[msg.sender][token] += amount;
		users[msg.sender].totalBorrowed += amount;
		users[msg.sender].lastUpdateTime = block.timestamp;
		users[msg.sender].isActive = true;
		markets[token].totalBorrow += amount;
		
		IERC20(token).safeTransfer(msg.sender, amount);

		emit Borrow(msg.sender, token, amount);	
	}

	function repay(address token, uint256 amount) external nonReentrant() whenNotPaused onlyActiveMarket(token){
		require(amount > 0, "Amount must be greater than 0");
		require(userBorrows[msg.sender][token] >= amount, "Insufficient borrow");

		IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
		userBorrows[msg.sender][token] -= amount;
		users[msg.sender].totalBorrowed -= amount;
		users[msg.sender].lastUpdateTime = block.timestamp;

		if (users[msg.sender].totalBorrowed == 0){
			users[msg.sender].isActive = false;
		}

		markets[token].totalBorrow -= amount;
		

		emit Repay(msg.sender, token, amount);
	}

	/**
	 * @dev Check if user can withdraw without making position unsafe
	 * @param user The user address to check
	 * @param token The token to withdraw
	 * @param amount The amount to withdraw
	 * @return True if user can withdraw, false otherwise
	 */
	function canWithdraw(address user, address token, uint256 amount) public view returns (bool) {
		uint256 currentRatio = getCollateralizationRatio(user);
		if(currentRatio == type(uint256).max) return true;

		//Calculate new ratio after withdraw
		uint256 newColleteralValue = 0;
		uint256 totalBorrowValue = 0;

		for (uint256 i = 0; i < supportedTokens.length; i++) {
			address supportedToken = supportedTokens[i];
			if(markets[supportedTokens].isActive) {
				uint256 depositAmount = userDeposits[user][supportedToken];
				uint256 borrowAmount = userBorrows[user][supportedToken];
				
				if(supportedToken == token){
					depositAmount = depositAmount > amount ? depositAmount - amount: 0;
				}

				if (depositAmount > 0) {
					newColleteralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINT;
				}

				if (borrowAmount > 0) {
					totalBorrowValue += borrowAmount;
				}
			}
		}

		if(totalBorrowValue = 0) return true;
		uint256 newRatio = (newColleteralValue * BASIS_POINT) / totalBorrowValue;

		return newRatio >= LIQUIDATION_THRESHOLD;
	}



	function isLiquidatable(address user) public view returns (bool) {
		uint256 ratio = getCollateralizationRatio(user);
		return ratio < LIQUIDATION_THRESHOLD;
	}

	function findBestCollateral(address user) internal view returns (address) {
		address bestToken = address(0);
		uint256 bestValue = 0;

		for (uint256 i = 0; i < supportedTokens.length; i++){
			address token = supportedTokens[i];
			if (markets[token].isActive && userDeposits[user][token] > 0) {
				uint256 value = (userDeposits[user][token] * markets[token].collateralFactor) / BASIS_POINT; 
				if(value > bestValue) {
					bestValue = value; 
					bestToken = token;
				}
			}
		}
	}


	function getCollateralizationRatio(address user) public view returns (uint256 ratio) {
		uint256 totalColleteralValue = 0;
		uint256 totalBorrowValue = 0;

		for (uint256 i = 0; i < supportedTokens.length; i++) {
			address token = supportedTokens[i];
			if (markets[token].isActive) {
				uint256 depositAmount = userDeposits[user][token];
				uint256 borrowAmount = userBorrows[user][token];

				if (depositAmount > 0) {
					totalColleteralValue += (depositAmount * markets[token].collateralFactor) / BASIS_POINT;
				}

				if (borrowAmount > 0) {
					totalBorrowValue += borrowAmount;
				}
			}
		}
	}

	/**
	 * @dev Pause the protocol
	 */
	function pause() external onlyOwner{
		_pause();
	}

	/**
	 * @dev Unpause the protocol 
	 */
	function unPause() external onlyOwner {
		_unpause();
	}
}