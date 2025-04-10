// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract NEOX is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 10_000_000_000 * 10**18; // 10 billion tokens
    
    constructor() ERC20("Neo Pantheon", "NEOX") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    //function mint(address to, uint256 amount) external onlyOwner {
    //    _mint(to, amount);
    //}
}
