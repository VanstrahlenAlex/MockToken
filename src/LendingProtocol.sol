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
	 * @dev Unpause the protocol
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