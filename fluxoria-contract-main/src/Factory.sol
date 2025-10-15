// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Fluxoria} from "./Fluxoria.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {OrderBook} from "./OrderBook.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Factory is Ownable, Pausable, ReentrancyGuard {
    address[] public allMarkets;
    mapping(address => bool) public isMarket;
    mapping(address => address) public marketToConditionalTokens;
    mapping(address => address) public conditionalTokensToMarket;
    mapping(address => address) public marketToOrderBook;
    mapping(address => address) public orderBookToMarket;
    
    // Collateral token management
    address public immutable COLLATERAL_TOKEN; // Primary collateral (USDC.e on Polygon)
    mapping(address => bool) public supportedCollaterals; // Multi-collateral support
    
    // Market creation parameters
    uint256 public marketCreationFee = 100 * 10**6; // 100 USDC.e (6 decimals)
    uint256 public minMarketDuration = 1 hours; // Minimum market duration
    uint256 public maxMarketDuration = 365 days; // Maximum market duration
    
    // Market creator whitelist (if enabled)
    bool public whitelistEnabled = false;
    mapping(address => bool) public whitelistedCreators;
    
    // Market categorization
    mapping(address => string) public marketCategory;
    mapping(address => string[]) public marketTags;
    mapping(string => address[]) public categoryMarkets;
    
    // Market creator tracking
    mapping(address => address[]) public creatorMarkets;
    mapping(address => uint256) public totalMarketsCreated;
    
    // Events
    event MarketCreated(
        address indexed owner,
        address indexed market,
        address indexed conditionalTokens,
        address orderBook,
        uint256 index,
        string question
    );
    
    event MarketCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event CollateralAdded(address indexed collateral);
    event CollateralRemoved(address indexed collateral);
    event WhitelistStatusChanged(bool enabled);
    event CreatorWhitelisted(address indexed creator);
    event CreatorRemovedFromWhitelist(address indexed creator);
    event MarketCategorized(address indexed market, string category);
    event MarketTagged(address indexed market, string[] tags);
    event MinMarketDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MaxMarketDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event FactoryPaused(address indexed by);
    event FactoryUnpaused(address indexed by);
    
    constructor(address _collateralToken) Ownable(msg.sender) {
        require(_collateralToken != address(0), "Invalid collateral token");
        COLLATERAL_TOKEN = _collateralToken;
        supportedCollaterals[_collateralToken] = true;
    }
    
    /**
     * @dev Create a new prediction market with conditional tokens
     * @param _name Array containing the market question
     * @param _symbol Array containing the market description
     * @param _expiredTime When the market should resolve
     * @param _outcomes Array of possible outcomes for the market
     */
    function createMarket(
        string[] memory _name, 
        string[] memory _symbol, 
        uint256 _expiredTime,
        string[] memory _outcomes
    ) external whenNotPaused nonReentrant returns (address market, address conditionalTokensContract) {
        // Check whitelist if enabled
        if (whitelistEnabled) {
            require(whitelistedCreators[msg.sender], "Not whitelisted");
        }
        
        require(_name.length > 0, "Question cannot be empty");
        require(_symbol.length > 0, "Description cannot be empty");
        require(_outcomes.length >= 2, "Must have at least 2 outcomes");
        require(_expiredTime > block.timestamp, "Resolution time must be in future");
        
        // Validate market duration
        uint256 duration = _expiredTime - block.timestamp;
        require(duration >= minMarketDuration, "Market duration too short");
        require(duration <= maxMarketDuration, "Market duration too long");
        
        // Collect market creation fee
        if (marketCreationFee > 0) {
            require(
                IERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), marketCreationFee),
                "Market creation fee transfer failed"
            );
        }
        
        // Deploy new Fluxoria market contract
        market = address(new Fluxoria(_name, _symbol, _expiredTime, COLLATERAL_TOKEN));
        
        // Get the conditional tokens and order book contracts from the market
        Fluxoria marketContract = Fluxoria(market);
        conditionalTokensContract = address(marketContract.conditionalTokens());
        address orderBookContract = address(marketContract.orderBook());
        
        // Register the market
        allMarkets.push(market);
        isMarket[market] = true;
        marketToConditionalTokens[market] = conditionalTokensContract;
        conditionalTokensToMarket[conditionalTokensContract] = market;
        marketToOrderBook[market] = orderBookContract;
        orderBookToMarket[orderBookContract] = market;
        
        // Track creator
        creatorMarkets[msg.sender].push(market);
        totalMarketsCreated[msg.sender]++;
        
        emit MarketCreated(
            msg.sender, 
            market, 
            conditionalTokensContract, 
            orderBookContract,
            allMarkets.length - 1,
            _name[0]
        );
    }
    
    /**
     * @dev Create a market with custom conditional tokens contract
     * @param _question The market question
     * @param _description The market description
     * @param _expiredTime When the market should resolve
     * @param _outcomes Array of possible outcomes
     * @param _outcomeType Type of market (Binary, MultiOutcome, Scalar)
     */
    function createMarketWithCustomTokens(
        string memory _question,
        string memory _description,
        uint256 _expiredTime,
        string[] memory _outcomes,
        ConditionalTokens.OutcomeType _outcomeType
    ) external whenNotPaused nonReentrant returns (address market, address conditionalTokensContract) {
        // Check whitelist if enabled
        if (whitelistEnabled) {
            require(whitelistedCreators[msg.sender], "Not whitelisted");
        }
        
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(_outcomes.length >= 2, "Must have at least 2 outcomes");
        require(_expiredTime > block.timestamp, "Resolution time must be in future");
        
        // Validate market duration
        uint256 duration = _expiredTime - block.timestamp;
        require(duration >= minMarketDuration, "Market duration too short");
        require(duration <= maxMarketDuration, "Market duration too long");
        
        // Collect market creation fee
        if (marketCreationFee > 0) {
            require(
                IERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), marketCreationFee),
                "Market creation fee transfer failed"
            );
        }
        
        // Deploy conditional tokens contract first
        conditionalTokensContract = address(new ConditionalTokens(COLLATERAL_TOKEN));
        
        // Create the market in the conditional tokens contract
        ConditionalTokens(conditionalTokensContract).createMarket(
            _question,
            _description,
            _expiredTime,
            _outcomeType,
            _outcomes
        );
        
        // Deploy new Fluxoria market contract
        string[] memory nameArray = new string[](1);
        nameArray[0] = _question;
        string[] memory symbolArray = new string[](1);
        symbolArray[0] = _description;
        market = address(new Fluxoria(nameArray, symbolArray, _expiredTime, COLLATERAL_TOKEN));
        
        // Get the order book contract from the market
        Fluxoria marketContract = Fluxoria(market);
        address orderBookContract = address(marketContract.orderBook());
        
        // Register the market
        allMarkets.push(market);
        isMarket[market] = true;
        marketToConditionalTokens[market] = conditionalTokensContract;
        conditionalTokensToMarket[conditionalTokensContract] = market;
        marketToOrderBook[market] = orderBookContract;
        orderBookToMarket[orderBookContract] = market;
        
        // Track creator
        creatorMarkets[msg.sender].push(market);
        totalMarketsCreated[msg.sender]++;
        
        emit MarketCreated(
            msg.sender, 
            market, 
            conditionalTokensContract, 
            orderBookContract,
            allMarkets.length - 1,
            _question
        );
    }
    
    /**
     * @dev Get all markets
     */
    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }
    
    /**
     * @dev Get market count
     */
    function getMarketLength() public view returns (uint256) {
        return allMarkets.length;
    }
    
    /**
     * @dev Get conditional tokens contract for a market
     */
    function getConditionalTokens(address market) external view returns (address) {
        return marketToConditionalTokens[market];
    }
    
    /**
     * @dev Get market for a conditional tokens contract
     */
    function getMarket(address conditionalTokens) external view returns (address) {
        return conditionalTokensToMarket[conditionalTokens];
    }
    
    /**
     * @dev Get order book contract for a market
     */
    function getOrderBook(address market) external view returns (address) {
        return marketToOrderBook[market];
    }
    
    /**
     * @dev Get market for an order book contract
     */
    function getMarketFromOrderBook(address orderBook) external view returns (address) {
        return orderBookToMarket[orderBook];
    }
    
    /**
     * @dev Update market creation fee (only owner)
     */
    function setMarketCreationFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = marketCreationFee;
        marketCreationFee = _newFee;
        emit MarketCreationFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Withdraw collected fees (only owner)
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        require(
            IERC20(COLLATERAL_TOKEN).transfer(owner(), balance),
            "Fee withdrawal failed"
        );
    }
    
    /**
     * @dev Get total collected fees
     */
    function getTotalFees() external view returns (uint256) {
        return IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
    }
    
    // ========== COLLATERAL MANAGEMENT ==========
    
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
        require(_collateral != COLLATERAL_TOKEN, "Cannot remove primary collateral");
        require(supportedCollaterals[_collateral], "Collateral not supported");
        
        supportedCollaterals[_collateral] = false;
        emit CollateralRemoved(_collateral);
    }
    
    /**
     * @dev Check if collateral is supported
     */
    function isCollateralSupported(address _collateral) external view returns (bool) {
        return supportedCollaterals[_collateral];
    }
    
    // ========== WHITELIST MANAGEMENT ==========
    
    /**
     * @dev Enable or disable whitelist (only owner)
     */
    function setWhitelistEnabled(bool _enabled) external onlyOwner {
        whitelistEnabled = _enabled;
        emit WhitelistStatusChanged(_enabled);
    }
    
    /**
     * @dev Add creator to whitelist (only owner)
     */
    function addToWhitelist(address _creator) external onlyOwner {
        require(_creator != address(0), "Invalid creator address");
        require(!whitelistedCreators[_creator], "Already whitelisted");
        
        whitelistedCreators[_creator] = true;
        emit CreatorWhitelisted(_creator);
    }
    
    /**
     * @dev Remove creator from whitelist (only owner)
     */
    function removeFromWhitelist(address _creator) external onlyOwner {
        require(whitelistedCreators[_creator], "Not whitelisted");
        
        whitelistedCreators[_creator] = false;
        emit CreatorRemovedFromWhitelist(_creator);
    }
    
    /**
     * @dev Batch add creators to whitelist (only owner)
     */
    function batchAddToWhitelist(address[] calldata _creators) external onlyOwner {
        for (uint256 i = 0; i < _creators.length; i++) {
            if (_creators[i] != address(0) && !whitelistedCreators[_creators[i]]) {
                whitelistedCreators[_creators[i]] = true;
                emit CreatorWhitelisted(_creators[i]);
            }
        }
    }
    
    // ========== MARKET CATEGORIZATION ==========
    
    /**
     * @dev Set category for a market (only owner)
     */
    function setMarketCategory(address _market, string calldata _category) external onlyOwner {
        require(isMarket[_market], "Not a valid market");
        
        marketCategory[_market] = _category;
        categoryMarkets[_category].push(_market);
        
        emit MarketCategorized(_market, _category);
    }
    
    /**
     * @dev Set tags for a market (only owner)
     */
    function setMarketTags(address _market, string[] calldata _tags) external onlyOwner {
        require(isMarket[_market], "Not a valid market");
        
        marketTags[_market] = _tags;
        
        emit MarketTagged(_market, _tags);
    }
    
    /**
     * @dev Get markets by category
     */
    function getMarketsByCategory(string calldata _category) external view returns (address[] memory) {
        return categoryMarkets[_category];
    }
    
    /**
     * @dev Get market tags
     */
    function getMarketTags(address _market) external view returns (string[] memory) {
        return marketTags[_market];
    }
    
    // ========== PARAMETER UPDATES ==========
    
    /**
     * @dev Update minimum market duration (only owner)
     */
    function setMinMarketDuration(uint256 _newDuration) external onlyOwner {
        require(_newDuration > 0, "Duration must be positive");
        require(_newDuration < maxMarketDuration, "Min must be less than max");
        
        uint256 oldDuration = minMarketDuration;
        minMarketDuration = _newDuration;
        
        emit MinMarketDurationUpdated(oldDuration, _newDuration);
    }
    
    /**
     * @dev Update maximum market duration (only owner)
     */
    function setMaxMarketDuration(uint256 _newDuration) external onlyOwner {
        require(_newDuration > minMarketDuration, "Max must be greater than min");
        
        uint256 oldDuration = maxMarketDuration;
        maxMarketDuration = _newDuration;
        
        emit MaxMarketDurationUpdated(oldDuration, _newDuration);
    }
    
    // ========== CREATOR TRACKING ==========
    
    /**
     * @dev Get all markets created by a specific creator
     */
    function getCreatorMarkets(address _creator) external view returns (address[] memory) {
        return creatorMarkets[_creator];
    }
    
    /**
     * @dev Get total markets created by a specific creator
     */
    function getCreatorMarketCount(address _creator) external view returns (uint256) {
        return totalMarketsCreated[_creator];
    }
    
    // ========== PAUSE/UNPAUSE ==========
    
    /**
     * @dev Pause factory operations (only owner)
     */
    function pause() external onlyOwner {
        _pause();
        emit FactoryPaused(msg.sender);
    }
    
    /**
     * @dev Unpause factory operations (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
        emit FactoryUnpaused(msg.sender);
    }
}


