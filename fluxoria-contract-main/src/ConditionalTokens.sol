// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ConditionalTokens is ERC20, Ownable, Pausable, ReentrancyGuard {
    // Market states
    enum MarketState { Active, Resolved, Cancelled }
    
    // Outcome types for different market scenarios
    enum OutcomeType { Binary, MultiOutcome, Scalar }
    
    struct Market {
        string question;
        string description;
        uint256 resolutionTime;
        MarketState state;
        OutcomeType outcomeType;
        string[] outcomes;
        uint256 winningOutcome;
        uint256 totalCollateral;
        address creator;
        bool isResolved;
    }
    
    // Market data
    mapping(uint256 => Market) public markets;
    uint256 public marketCount;
    
    // Token balances for each outcome
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public outcomeBalances;
    
    // Allowances for outcome token transfers: marketId => owner => spender => outcome => amount
    mapping(uint256 => mapping(address => mapping(address => mapping(uint256 => uint256)))) public outcomeAllowances;
    
    // Multi-collateral support
    IERC20 public collateralToken; // Primary collateral token
    mapping(address => bool) public supportedCollaterals; // Supported collateral tokens
    mapping(uint256 => address) public marketCollateral; // Market-specific collateral
    
    // Market fee structure
    uint256 public mintFee = 10; // 0.1% minting fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public collectedFees;
    
    // Events
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint256 resolutionTime,
        OutcomeType outcomeType
    );
    
    event TokensMinted(
        uint256 indexed marketId,
        address indexed user,
        uint256 outcome,
        uint256 amount
    );
    
    event TokensBurned(
        uint256 indexed marketId,
        address indexed user,
        uint256 outcome,
        uint256 amount
    );
    
    event MarketResolved(
        uint256 indexed marketId,
        uint256 winningOutcome,
        uint256 totalPayout
    );
    
    event TokensRedeemed(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount,
        uint256 outcome
    );
    
    event CollateralAdded(address indexed collateral);
    event CollateralRemoved(address indexed collateral);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesCollected(uint256 amount);
    event MarketPaused(address indexed by);
    event MarketUnpaused(address indexed by);
    
    constructor(address _collateralToken) ERC20("Conditional Tokens", "CT") Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        supportedCollaterals[_collateralToken] = true;
    }
    
    /**
     * @dev Create a new prediction market
     * @param _question The question/event being predicted
     * @param _description Detailed description of the market
     * @param _resolutionTime When the market should resolve
     * @param _outcomeType Type of market (Binary, MultiOutcome, Scalar)
     * @param _outcomes Array of possible outcomes
     */
    function createMarket(
        string memory _question,
        string memory _description,
        uint256 _resolutionTime,
        OutcomeType _outcomeType,
        string[] memory _outcomes
    ) external whenNotPaused returns (uint256 marketId) {
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(_resolutionTime > block.timestamp, "Resolution time must be in future");
        require(_outcomes.length >= 2, "Must have at least 2 outcomes");
        
        marketId = marketCount++;
        
        markets[marketId] = Market({
            question: _question,
            description: _description,
            resolutionTime: _resolutionTime,
            state: MarketState.Active,
            outcomeType: _outcomeType,
            outcomes: _outcomes,
            winningOutcome: 0,
            totalCollateral: 0,
            creator: msg.sender,
            isResolved: false
        });
        
        // Set market to use primary collateral by default
        marketCollateral[marketId] = address(collateralToken);
        
        emit MarketCreated(marketId, msg.sender, _question, _resolutionTime, _outcomeType);
    }
    
    /**
     * @dev Mint conditional tokens for a specific outcome
     * @param _marketId The market ID
     * @param _outcome The outcome index
     * @param _amount Amount of collateral to deposit
     */
    function mintTokens(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount
    ) external whenNotPaused nonReentrant {
        require(_marketId < marketCount, "Market does not exist");
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Active, "Market not active");
        require(_outcome < market.outcomes.length, "Invalid outcome");
        require(_amount > 0, "Amount must be positive");
        
        // Calculate fee
        uint256 fee = (_amount * mintFee) / FEE_DENOMINATOR;
        uint256 totalRequired = _amount + fee;
        
        // Get market-specific collateral
        address marketCollateralToken = marketCollateral[_marketId];
        require(supportedCollaterals[marketCollateralToken], "Collateral not supported");
        
        // Transfer collateral + fee from user
        require(
            IERC20(marketCollateralToken).transferFrom(msg.sender, address(this), totalRequired),
            "Collateral transfer failed"
        );
        
        // Add fee to collected fees
        collectedFees += fee;
        
        // Mint conditional tokens
        outcomeBalances[_marketId][msg.sender][_outcome] += _amount;
        market.totalCollateral += _amount;
        
        emit TokensMinted(_marketId, msg.sender, _outcome, _amount);
        if (fee > 0) {
            emit FeesCollected(fee);
        }
    }
    
    /**
     * @dev Burn conditional tokens and get collateral back
     * @param _marketId The market ID
     * @param _outcome The outcome index
     * @param _amount Amount of tokens to burn
     */
    function burnTokens(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount
    ) external whenNotPaused nonReentrant {
        require(_marketId < marketCount, "Market does not exist");
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Active, "Market not active");
        require(_outcome < market.outcomes.length, "Invalid outcome");
        require(_amount > 0, "Amount must be positive");
        require(
            outcomeBalances[_marketId][msg.sender][_outcome] >= _amount,
            "Insufficient token balance"
        );
        
        // Get market-specific collateral
        address marketCollateralToken = marketCollateral[_marketId];
        
        // Burn conditional tokens
        outcomeBalances[_marketId][msg.sender][_outcome] -= _amount;
        market.totalCollateral -= _amount;
        
        // Return collateral to user
        require(
            IERC20(marketCollateralToken).transfer(msg.sender, _amount),
            "Collateral transfer failed"
        );
        
        emit TokensBurned(_marketId, msg.sender, _outcome, _amount);
    }
    
    /**
     * @dev Resolve a market with the winning outcome
     * @param _marketId The market ID
     * @param _winningOutcome The winning outcome index
     */
    function resolveMarket(
        uint256 _marketId,
        uint256 _winningOutcome
    ) external onlyOwner {
        require(_marketId < marketCount, "Market does not exist");
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Active, "Market not active");
        require(block.timestamp >= market.resolutionTime, "Market not ready for resolution");
        require(_winningOutcome < market.outcomes.length, "Invalid winning outcome");
        
        market.state = MarketState.Resolved;
        market.winningOutcome = _winningOutcome;
        market.isResolved = true;
        
        emit MarketResolved(_marketId, _winningOutcome, market.totalCollateral);
    }
    
    /**
     * @dev Redeem winning tokens for collateral
     * @param _marketId The market ID
     * @param _outcome The outcome to redeem
     */
    function redeemTokens(
        uint256 _marketId,
        uint256 _outcome
    ) external {
        require(_marketId < marketCount, "Market does not exist");
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Resolved, "Market not resolved");
        require(_outcome == market.winningOutcome, "Not the winning outcome");
        
        uint256 amount = outcomeBalances[_marketId][msg.sender][_outcome];
        require(amount > 0, "No tokens to redeem");
        
        // Clear the balance
        outcomeBalances[_marketId][msg.sender][_outcome] = 0;
        
        // Transfer collateral to user
        require(
            collateralToken.transfer(msg.sender, amount),
            "Collateral transfer failed"
        );
        
        emit TokensRedeemed(_marketId, msg.sender, amount, _outcome);
    }
    
    /**
     * @dev Get user's token balance for a specific outcome
     * @param _marketId The market ID
     * @param _user The user address
     * @param _outcome The outcome index
     */
    function getOutcomeBalance(
        uint256 _marketId,
        address _user,
        uint256 _outcome
    ) external view returns (uint256) {
        return outcomeBalances[_marketId][_user][_outcome];
    }
    
    /**
     * @dev Transfer outcome tokens to another address
     * @param _marketId The market ID
     * @param _to The recipient address
     * @param _outcome The outcome index
     * @param _amount The amount to transfer
     */
    function transferOutcomeTokens(
        uint256 _marketId,
        address _to,
        uint256 _outcome,
        uint256 _amount
    ) external whenNotPaused {
        require(_marketId < marketCount, "Market does not exist");
        require(_to != address(0), "Cannot transfer to zero address");
        require(_amount > 0, "Amount must be positive");
        require(
            outcomeBalances[_marketId][msg.sender][_outcome] >= _amount,
            "Insufficient balance"
        );
        
        outcomeBalances[_marketId][msg.sender][_outcome] -= _amount;
        outcomeBalances[_marketId][_to][_outcome] += _amount;
        
        emit Transfer(msg.sender, _to, _amount);
    }
    
    /**
     * @dev Transfer outcome tokens from one address to another (with approval)
     * @param _marketId The market ID
     * @param _from The sender address
     * @param _to The recipient address
     * @param _outcome The outcome index
     * @param _amount The amount to transfer
     */
    function transferOutcomeTokensFrom(
        uint256 _marketId,
        address _from,
        address _to,
        uint256 _outcome,
        uint256 _amount
    ) external whenNotPaused {
        require(_marketId < marketCount, "Market does not exist");
        require(_from != address(0), "Cannot transfer from zero address");
        require(_to != address(0), "Cannot transfer to zero address");
        require(_amount > 0, "Amount must be positive");
        require(
            outcomeBalances[_marketId][_from][_outcome] >= _amount,
            "Insufficient balance"
        );
        
        // Check and update allowance if not transferring own tokens
        if (msg.sender != _from) {
            uint256 currentAllowance = outcomeAllowances[_marketId][_from][msg.sender][_outcome];
            require(currentAllowance >= _amount, "Insufficient allowance");
            if (currentAllowance != type(uint256).max) {
                outcomeAllowances[_marketId][_from][msg.sender][_outcome] = currentAllowance - _amount;
            }
        }
        
        outcomeBalances[_marketId][_from][_outcome] -= _amount;
        outcomeBalances[_marketId][_to][_outcome] += _amount;
        
        emit Transfer(_from, _to, _amount);
    }
    
    /**
     * @dev Approve another address to transfer outcome tokens
     * @param _marketId The market ID
     * @param _spender The address to approve
     * @param _outcome The outcome index
     * @param _amount The amount to approve
     */
    function approveOutcomeTokens(
        uint256 _marketId,
        address _spender,
        uint256 _outcome,
        uint256 _amount
    ) external {
        require(_spender != address(0), "Cannot approve zero address");
        outcomeAllowances[_marketId][msg.sender][_spender][_outcome] = _amount;
        emit Approval(msg.sender, _spender, _amount);
    }
    
    /**
     * @dev Get the allowance for outcome tokens
     * @param _marketId The market ID
     * @param _owner The owner address
     * @param _spender The spender address
     * @param _outcome The outcome index
     */
    function allowanceOutcomeTokens(
        uint256 _marketId,
        address _owner,
        address _spender,
        uint256 _outcome
    ) external view returns (uint256) {
        return outcomeAllowances[_marketId][_owner][_spender][_outcome];
    }
    
    /**
     * @dev Get market information
     * @param _marketId The market ID
     */
    function getMarket(uint256 _marketId) external view returns (Market memory) {
        require(_marketId < marketCount, "Market does not exist");
        return markets[_marketId];
    }
    
    /**
     * @dev Get all outcomes for a market
     * @param _marketId The market ID
     */
    function getMarketOutcomes(uint256 _marketId) external view returns (string[] memory) {
        require(_marketId < marketCount, "Market does not exist");
        return markets[_marketId].outcomes;
    }
    
    /**
     * @dev Check if a market is active
     * @param _marketId The market ID
     */
    function isMarketActive(uint256 _marketId) external view returns (bool) {
        require(_marketId < marketCount, "Market does not exist");
        return markets[_marketId].state == MarketState.Active;
    }
    
    /**
     * @dev Get total number of markets
     */
    function getMarketCount() external view returns (uint256) {
        return marketCount;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @dev Add support for a new collateral token (only owner)
     */
    function addCollateral(address _collateral) external onlyOwner {
        require(_collateral != address(0), "Invalid collateral address");
        require(!supportedCollaterals[_collateral], "Collateral already supported");
        
        supportedCollaterals[_collateral] = true;
        emit CollateralAdded(_collateral);
    }
    
    /**
     * @dev Remove support for a collateral token (only owner)
     */
    function removeCollateral(address _collateral) external onlyOwner {
        require(_collateral != address(collateralToken), "Cannot remove primary collateral");
        require(supportedCollaterals[_collateral], "Collateral not supported");
        
        supportedCollaterals[_collateral] = false;
        emit CollateralRemoved(_collateral);
    }
    
    /**
     * @dev Set collateral for a specific market (only owner)
     */
    function setMarketCollateral(uint256 _marketId, address _collateral) external onlyOwner {
        require(_marketId < marketCount, "Market does not exist");
        require(supportedCollaterals[_collateral], "Collateral not supported");
        require(markets[_marketId].totalCollateral == 0, "Market has existing collateral");
        
        marketCollateral[_marketId] = _collateral;
    }
    
    /**
     * @dev Update mint fee (only owner)
     */
    function setMintFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 100, "Fee too high"); // Max 1%
        uint256 oldFee = mintFee;
        mintFee = _newFee;
        emit MintFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Withdraw collected fees (only owner)
     */
    function withdrawFees(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        require(collectedFees > 0, "No fees to withdraw");
        
        uint256 amount = collectedFees;
        collectedFees = 0;
        
        require(
            collateralToken.transfer(_recipient, amount),
            "Fee withdrawal failed"
        );
    }
    
    /**
     * @dev Pause all market operations (only owner)
     */
    function pause() external onlyOwner {
        _pause();
        emit MarketPaused(msg.sender);
    }
    
    /**
     * @dev Unpause all market operations (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
        emit MarketUnpaused(msg.sender);
    }
    
    /**
     * @dev Get collected fees
     */
    function getCollectedFees() external view returns (uint256) {
        return collectedFees;
    }
    
    /**
     * @dev Check if collateral is supported
     */
    function isCollateralSupported(address _collateral) external view returns (bool) {
        return supportedCollaterals[_collateral];
    }
    
    /**
     * @dev Get market collateral token
     */
    function getMarketCollateral(uint256 _marketId) external view returns (address) {
        require(_marketId < marketCount, "Market does not exist");
        return marketCollateral[_marketId];
    }
}
