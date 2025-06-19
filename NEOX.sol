// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract NEOX is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    uint256 public constant INITIAL_SUPPLY = 10_000_000_000 * 10**18; // 10 billion tokens
    uint256 public constant MAX_ALLOWANCE = 1_000_000 * 10**18; // 1M tokens max allowance
    uint256 public constant OWNERSHIP_TRANSFER_DELAY = 48 hours; // 48 hour timelock
    uint256 public constant ALLOWANCE_INCREASE_COOLDOWN = 1 hours; // 1 hour cooldown
    uint256 public constant LARGE_TRANSFER_THRESHOLD = 100_000 * 10**18; // 100K tokens
    
    // Ownership transfer timelock
    mapping(address => uint256) public pendingOwnershipTransfer;
    mapping(address => bool) public verifiedAddresses;
    
    // Allowance management with strict controls
    mapping(address => mapping(address => uint256)) public lastAllowanceIncrease;
    mapping(address => mapping(address => uint256)) public allowanceCount;
    uint256 public constant MAX_ALLOWANCE_COUNT = 10; // Max allowances per spender
    
    // Token whitelisting for external interactions
    mapping(address => bool) public whitelistedTokens;
    mapping(address => bool) public blacklistedTokens;
    
    // Emergency controls
    bool public emergencyStop;
    mapping(address => bool) public emergencyExempt;
    
    // Commit-reveal scheme for large transfers
    mapping(bytes32 => bool) public committedHashes;
    mapping(bytes32 => address) public commitOwners;
    mapping(bytes32 => uint256) public commitTimestamps;
    uint256 public constant COMMIT_EXPIRY = 1 hours; // 1 hour expiry for commits
    
    // Front-running protection
    mapping(address => uint256) public lastTransferTime;
    uint256 public constant TRANSFER_COOLDOWN = 1 minutes; // 1 minute cooldown
    
    // Cross-chain replay protection
    mapping(bytes32 => bool) public usedSignatures;
    mapping(address => uint256) public signatureNonces;
    
    event OwnershipTransferInitiated(address indexed oldOwner, address indexed newOwner, uint256 effectiveTime);
    event OwnershipTransferCompleted(address indexed oldOwner, address indexed newOwner);
    event OwnershipTransferRestricted(address indexed oldOwner, address indexed newOwner);
    event TokenWhitelistUpdated(address indexed token, bool whitelisted);
    event TokenBlacklistUpdated(address indexed token, bool blacklisted);
    event EmergencyStopSet(bool stopped);
    event EmergencyExemptUpdated(address indexed account, bool exempt);
    event TransferCommitted(bytes32 indexed hash, address indexed owner);
    event TransferRevealed(bytes32 indexed hash, address indexed from, address indexed to, uint256 amount);
    event LargeTransferDetected(address indexed from, address indexed to, uint256 amount);
    event AllowanceLimitReached(address indexed owner, address indexed spender);
    event TransferCooldownApplied(address indexed from, address indexed to);
    
    constructor() ERC20("Neo Pantheon", "NEOX") Ownable(msg.sender) {
        verifiedAddresses[msg.sender] = true;
        emergencyExempt[msg.sender] = true;
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    modifier whenNotStopped() {
        require(!emergencyStop || emergencyExempt[msg.sender], "Contract is paused");
        _;
    }
    
    modifier onlyVerified() {
        require(verifiedAddresses[msg.sender], "Address not verified");
        _;
    }
    
    modifier validAddress(address addr) {
        require(addr != address(0), "Invalid address");
        _;
    }
    
    modifier transferCooldown() {
        require(block.timestamp >= lastTransferTime[msg.sender] + TRANSFER_COOLDOWN, "Transfer cooldown active");
        _;
        lastTransferTime[msg.sender] = block.timestamp;
    }
       
    // Secure transfer function with reentrancy protection and cooldown
    function transfer(address to, uint256 amount) public override whenNotStopped nonReentrant validAddress(to) transferCooldown returns (bool) {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= balanceOf(msg.sender), "Insufficient balance");
        
        // Check for large transfers
        if (amount >= LARGE_TRANSFER_THRESHOLD) {
            emit LargeTransferDetected(msg.sender, to, amount);
        }
        
        return super.transfer(to, amount);
    }
  
    // Secure transferFrom function with reentrancy protection and cooldown
    function transferFrom(address from, address to, uint256 amount) public override whenNotStopped nonReentrant validAddress(to) transferCooldown returns (bool) {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= balanceOf(from), "Insufficient balance");
        require(amount <= allowance(from, msg.sender), "Insufficient allowance");
        
        // Check for large transfers
        if (amount >= LARGE_TRANSFER_THRESHOLD) {
            emit LargeTransferDetected(from, to, amount);
        }
        
        return super.transferFrom(from, to, amount);
    }
    
    // Secure approve function with race condition protection and limits
    function approve(address spender, uint256 amount) public override whenNotStopped validAddress(spender) returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "Reset allowance to 0 first");
        require(amount <= MAX_ALLOWANCE, "Allowance exceeds maximum");
        require(amount <= balanceOf(msg.sender), "Allowance exceeds balance");
        
        // Limit number of allowances per spender
        if (amount > 0 && allowanceCount[msg.sender][spender] >= MAX_ALLOWANCE_COUNT) {
            emit AllowanceLimitReached(msg.sender, spender);
            revert("Too many allowances for this spender");
        }
        
        if (amount > 0) {
            allowanceCount[msg.sender][spender]++;
        }
        
        return super.approve(spender, amount);
    }

    // Secure increaseAllowance with strict rate limiting and overflow protection
    function increaseAllowance(address spender, uint256 addedValue) public whenNotStopped validAddress(spender) returns (bool) {
        require(block.timestamp >= lastAllowanceIncrease[msg.sender][spender] + ALLOWANCE_INCREASE_COOLDOWN, "Cooldown not met");
        
        uint256 currentAllowance = allowance(msg.sender, spender);
        uint256 newAllowance = currentAllowance + addedValue;
        require(newAllowance >= currentAllowance, "Allowance overflow");
        require(newAllowance <= MAX_ALLOWANCE, "Allowance exceeds maximum");
        require(newAllowance <= balanceOf(msg.sender), "Allowance exceeds balance");
        
        lastAllowanceIncrease[msg.sender][spender] = block.timestamp;
        _approve(msg.sender, spender, newAllowance);
        return true;
    }

    // Secure decreaseAllowance with underflow protection
    function decreaseAllowance(address spender, uint256 subtractedValue) public whenNotStopped validAddress(spender) returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    // Initiate ownership transfer with timelock and verification
    function initiateOwnershipTransfer(address newOwner) external onlyOwner validAddress(newOwner) {
        require(newOwner != owner(), "New owner cannot be current owner");
        require(verifiedAddresses[newOwner], "New owner must be verified");
        require(pendingOwnershipTransfer[newOwner] == 0, "Transfer already pending");
        
        pendingOwnershipTransfer[newOwner] = block.timestamp + OWNERSHIP_TRANSFER_DELAY;
        emit OwnershipTransferInitiated(owner(), newOwner, pendingOwnershipTransfer[newOwner]);
    }

    // Complete ownership transfer after timelock
    function completeOwnershipTransfer(address newOwner) external validAddress(newOwner) {
        require(pendingOwnershipTransfer[newOwner] > 0, "No pending transfer");
        require(block.timestamp >= pendingOwnershipTransfer[newOwner], "Delay not met");
        require(msg.sender == newOwner || msg.sender == owner(), "Not authorized");
        
        address oldOwner = owner();
        _transferOwnership(newOwner);
        delete pendingOwnershipTransfer[newOwner];
        
        // Update emergency exempt status
        emergencyExempt[oldOwner] = false;
        emergencyExempt[newOwner] = true;
        
        emit OwnershipTransferCompleted(oldOwner, newOwner);
    }

    // Renounce ownership to make contract immutable
    function renounceOwnership() public virtual override onlyOwner {
        _transferOwnership(address(0));
        emit OwnershipTransferRestricted(owner(), address(0));
    }

    // Set address verification status
    function setVerifiedAddress(address addr, bool verified) external onlyOwner validAddress(addr) {
        verifiedAddresses[addr] = verified;
    }
    
    // Set token whitelist status
    function setTokenWhitelist(address token, bool whitelisted) external onlyOwner validAddress(token) {
        whitelistedTokens[token] = whitelisted;
        emit TokenWhitelistUpdated(token, whitelisted);
    }

    // Set token blacklist status
    function setTokenBlacklist(address token, bool blacklisted) external onlyOwner validAddress(token) {
        blacklistedTokens[token] = blacklisted;
        emit TokenBlacklistUpdated(token, blacklisted);
    }

    // Safe transfer from external token (whitelisted only)
    function safeTransferFromExternal(address token, address from, address to, uint256 amount) external whenNotStopped nonReentrant {
        require(whitelistedTokens[token], "Token not whitelisted");
        require(!blacklistedTokens[token], "Token is blacklisted");
        require(to != address(this), "Cannot transfer to self");
        require(verifiedAddresses[msg.sender], "Caller not verified");
        
        IERC20(token).safeTransferFrom(from, to, amount);
    }
    
    // Set emergency stop
    function setEmergencyStop(bool stop) external onlyOwner {
        emergencyStop = stop;
        emit EmergencyStopSet(stop);
    }

    // Set emergency exempt status
    function setEmergencyExempt(address account, bool exempt) external onlyOwner validAddress(account) {
        emergencyExempt[account] = exempt;
        emit EmergencyExemptUpdated(account, exempt);
    }
    
    // Commit a transfer hash for large transfers
    function commitTransfer(bytes32 hash) external whenNotStopped {
        require(!committedHashes[hash], "Hash already committed");
        require(commitTimestamps[hash] == 0, "Hash already committed");
        
        committedHashes[hash] = true;
        commitOwners[hash] = msg.sender;
        commitTimestamps[hash] = block.timestamp;
        emit TransferCommitted(hash, msg.sender);
    }

    // Reveal and execute a committed transfer
    function revealTransfer(address to, uint256 amount, bytes32 salt) external whenNotStopped nonReentrant validAddress(to) {
        bytes32 hash = keccak256(abi.encodePacked(to, amount, salt, msg.sender));
        require(committedHashes[hash], "Hash not committed");
        require(commitOwners[hash] == msg.sender, "Not commit owner");
        require(amount >= LARGE_TRANSFER_THRESHOLD, "Amount below threshold");
        require(block.timestamp <= commitTimestamps[hash] + COMMIT_EXPIRY, "Commit expired");
        
        delete committedHashes[hash];
        delete commitOwners[hash];
        delete commitTimestamps[hash];
        
        _transfer(msg.sender, to, amount);
        emit TransferRevealed(hash, msg.sender, to, amount);
    }
    
    // Signature-based approval with replay protection
    function approveWithSignature(
        address spender, 
        uint256 amount, 
        uint256 deadline, 
        bytes32 signatureHash,
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external whenNotStopped validAddress(spender) {
        require(deadline >= block.timestamp, "Signature expired");
        require(!usedSignatures[signatureHash], "Signature already used");
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            spender,
            amount,
            deadline,
            signatureNonces[msg.sender],
            block.chainid
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        require(signer == msg.sender, "Invalid signature");
        
        usedSignatures[signatureHash] = true;
        signatureNonces[msg.sender]++;
        
        require(amount <= MAX_ALLOWANCE, "Allowance exceeds maximum");
        require(amount <= balanceOf(msg.sender), "Allowance exceeds balance");
        
        _approve(msg.sender, spender, amount);
    }
    
    // Get pending ownership transfer time
    function getPendingOwnershipTransfer(address newOwner) external view returns (uint256) {
        return pendingOwnershipTransfer[newOwner];
    }

    // Check if ownership transfer is ready
    function isOwnershipTransferReady(address newOwner) external view returns (bool) {
        return pendingOwnershipTransfer[newOwner] > 0 && block.timestamp >= pendingOwnershipTransfer[newOwner];
    }

    // Get last allowance increase time
    function getLastAllowanceIncrease(address owner, address spender) external view returns (uint256) {
        return lastAllowanceIncrease[owner][spender];
    }

    // Get allowance count for a spender
    function getAllowanceCount(address owner, address spender) external view returns (uint256) {
        return allowanceCount[owner][spender];
    }

    // Get signature nonce for replay protection
    function getSignatureNonce(address owner) external view returns (uint256) {
        return signatureNonces[owner];
    }

    // Check if signature has been used
    function isSignatureUsed(bytes32 signatureHash) external view returns (bool) {
        return usedSignatures[signatureHash];
    }
    
    // Override _update to add additional security checks
    function _update(address from, address to, uint256 amount) internal virtual override whenNotStopped {
        require(from != address(0) || to != address(0), "Invalid transfer");
        require(amount > 0, "Amount must be greater than 0");
        
        // Only check balance for transfers (not minting)
        if (from != address(0)) {
            require(amount <= balanceOf(from), "Insufficient balance");
        }
        
        super._update(from, to, amount);
    }
    
    // Receive function to accept ETH (for emergency purposes)
    receive() external payable {
        // Contract can receive ETH for emergency purposes
    }
    
    // Emergency function to recover stuck tokens
    function emergencyRecoverToken(address token, address to, uint256 amount) external onlyOwner validAddress(to) {
        require(token != address(this), "Cannot recover NEOX tokens");
        IERC20(token).safeTransfer(to, amount);
    }

    // Emergency function to recover ETH
    function emergencyRecoverETH(address payable to, uint256 amount) external onlyOwner validAddress(to) {
        require(amount <= address(this).balance, "Insufficient ETH balance");
        to.transfer(amount);
    }
    
    // Clear expired commits
    function clearExpiredCommits(bytes32[] calldata hashes) external {
        for (uint256 i = 0; i < hashes.length; i++) {
            bytes32 hash = hashes[i];
            if (committedHashes[hash] && block.timestamp > commitTimestamps[hash] + COMMIT_EXPIRY) {
                delete committedHashes[hash];
                delete commitOwners[hash];
                delete commitTimestamps[hash];
            }
        }
    }

    // Reset allowance count for a spender (emergency use)
    function resetAllowanceCount(address owner, address spender) external onlyOwner {
        allowanceCount[owner][spender] = 0;
    }
}
