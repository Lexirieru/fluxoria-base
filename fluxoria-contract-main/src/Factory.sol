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
    // Custom errors
    error InvalidCollateralToken();
    error NotWhitelisted();
    error QuestionCannotBeEmpty();
    error DescriptionCannotBeEmpty();
    error MustHaveAtLeast2Outcomes();
    error ResolutionTimeMustBeInFuture();
    error MarketDurationTooShort();
    error MarketDurationTooLong();
    error MarketCreationFeeTransferFailed();
    error NoFeesToWithdraw();
    error FeeWithdrawalFailed();
    error InvalidCollateralAddress();
    error CollateralAlreadySupported();
    error CannotRemovePrimaryCollateral();
    error CollateralNotSupported();
    error InvalidCreatorAddress();
    error AlreadyWhitelisted();
    error NotWhitelistedCreator();
    error NotAValidMarket();
    error DurationMustBePositive();
    error MinMustBeLessThanMax();
    error MaxMustBeGreaterThanMin();
    
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
        if (_collateralToken == address(0)) revert InvalidCollateralToken();
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
            if (!whitelistedCreators[msg.sender]) revert NotWhitelisted();
        }
        
        if (_name.length == 0) revert QuestionCannotBeEmpty();
        if (_symbol.length == 0) revert DescriptionCannotBeEmpty();
        if (_outcomes.length < 2) revert MustHaveAtLeast2Outcomes();
        if (_expiredTime <= block.timestamp) revert ResolutionTimeMustBeInFuture();
        
        // Validate market duration
        uint256 duration = _expiredTime - block.timestamp;
        if (duration < minMarketDuration) revert MarketDurationTooShort();
        if (duration > maxMarketDuration) revert MarketDurationTooLong();
        
        // Collect market creation fee
        if (marketCreationFee > 0) {
            if (!IERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), marketCreationFee)) {
                revert MarketCreationFeeTransferFailed();
            }
        }
        
        // Deploy new Fluxoria market contract
        market = address(new Fluxoria(_name, _symbol, _expiredTime, COLLATERAL_TOKEN));
        
        // Get the conditional tokens and order book contracts from the market
        Fluxoria marketContract = Fluxoria(market);
        conditionalTokensContract = address(marketContract.conditionalTokens());
        address orderBookContract = address(marketContract.orderBook());
        
        // Transfer ownership of the market to the creator
        marketContract.transferOwnership(msg.sender);
        
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
            if (!whitelistedCreators[msg.sender]) revert NotWhitelisted();
        }
        
        if (bytes(_question).length == 0) revert QuestionCannotBeEmpty();
        if (bytes(_description).length == 0) revert DescriptionCannotBeEmpty();
        if (_outcomes.length < 2) revert MustHaveAtLeast2Outcomes();
        if (_expiredTime <= block.timestamp) revert ResolutionTimeMustBeInFuture();
        
        // Validate market duration
        uint256 duration = _expiredTime - block.timestamp;
        if (duration < minMarketDuration) revert MarketDurationTooShort();
        if (duration > maxMarketDuration) revert MarketDurationTooLong();
        
        // Collect market creation fee
        if (marketCreationFee > 0) {
            if (!IERC20(COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), marketCreationFee)) {
                revert MarketCreationFeeTransferFailed();
            }
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
        
        // Transfer ownership of the market to the creator
        marketContract.transferOwnership(msg.sender);
        
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
        if (balance == 0) revert NoFeesToWithdraw();
        if (!IERC20(COLLATERAL_TOKEN).transfer(owner(), balance)) {
            revert FeeWithdrawalFailed();
        }
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
        if (_collateral == address(0)) revert InvalidCollateralAddress();
        if (supportedCollaterals[_collateral]) revert CollateralAlreadySupported();
        
        supportedCollaterals[_collateral] = true;
        emit CollateralAdded(_collateral);
    }
    
    /**
     * @dev Remove support for a collateral token (only owner)
     */
    function removeCollateral(address _collateral) external onlyOwner {
        if (_collateral == COLLATERAL_TOKEN) revert CannotRemovePrimaryCollateral();
        if (!supportedCollaterals[_collateral]) revert CollateralNotSupported();
        
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
        if (_creator == address(0)) revert InvalidCreatorAddress();
        if (whitelistedCreators[_creator]) revert AlreadyWhitelisted();
        
        whitelistedCreators[_creator] = true;
        emit CreatorWhitelisted(_creator);
    }
    
    /**
     * @dev Remove creator from whitelist (only owner)
     */
    function removeFromWhitelist(address _creator) external onlyOwner {
        if (!whitelistedCreators[_creator]) revert NotWhitelistedCreator();
        
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
        if (!isMarket[_market]) revert NotAValidMarket();
        
        marketCategory[_market] = _category;
        categoryMarkets[_category].push(_market);
        
        emit MarketCategorized(_market, _category);
    }
    
    /**
     * @dev Set tags for a market (only owner)
     */
    function setMarketTags(address _market, string[] calldata _tags) external onlyOwner {
        if (!isMarket[_market]) revert NotAValidMarket();
        
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
        if (_newDuration == 0) revert DurationMustBePositive();
        if (_newDuration >= maxMarketDuration) revert MinMustBeLessThanMax();
        
        uint256 oldDuration = minMarketDuration;
        minMarketDuration = _newDuration;
        
        emit MinMarketDurationUpdated(oldDuration, _newDuration);
    }
    
    /**
     * @dev Update maximum market duration (only owner)
     */
    function setMaxMarketDuration(uint256 _newDuration) external onlyOwner {
        if (_newDuration <= minMarketDuration) revert MaxMustBeGreaterThanMin();
        
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


