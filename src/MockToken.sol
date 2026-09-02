// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract MockToken is ERC20, Ownable {
    uint8 private _decimals;

	/**
	 * @dev Constructor to initialize the token
	 * @param name The name of the token
	 * @param symbol The symbol of the token
	 * @param decimals_ The number of decimals
	 * @param initialSuply The initial supply of tokens
	 */

	constructor(
		string memory name,
		string memory symbol,
		uint8 decimals_,
		uint256 initialSuply
	) ERC20(name, symbol) Ownable(msg.sender) {
		_decimals = decimals_;
		_mint(msg.sender, initialSuply);
	}

	/**
	 * @dev Mint new tokens (only owner)
	 * @param to The address to mint tokens to
	 * @param amount The amount to mint
	 */

	function mint(address to, uint256 amount)  external onlyOwner {
		_mint(to, amount);
	}

	/**
	 * @dev Burn tokens from caller
	 * @param amount The amount to burn
	 */

	function burn(uint256 amount) external {
		_burn(msg.sender, amount);
	}

	/**
	 * @dev Burn tokens from a specific address (only owner)
	 * @param from The address to burn tokens from
	 * @param amount The amount to burn
	 */

	function burnFrom(address from, uint256 amount) external onlyOwner {
		_burn(from, amount);
	}

	/**
	 * @dev Get the number of decimals
	 * @return The number of decimals
	 */

	function decimals() public view override returns (uint8) {
		return _decimals;
	}
}