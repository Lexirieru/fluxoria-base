// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../src/Factory.sol";
import {Fluxoria} from "../src/Fluxoria.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    
    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }
    
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Invalid address");
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "Insufficient balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0) && spender != address(0), "Invalid address");
        _allowances[owner][spender] = amount;
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    
    function mint(address to, uint256 amount) public {
        require(to != address(0), "Invalid address");
        _totalSupply += amount;
        unchecked { _balances[to] += amount; }
    }
}

/**
 * @title FactoryEnhancementTest
 * @notice Tests for new enhancement features in Factory contract:
 * - Multi-collateral support
 * - Whitelist system
 * - Market categorization & tagging
 * - Creator tracking
 * - Market duration validation
 * - Emergency pause/unpause
 */
contract FactoryEnhancementTest is Test {
    Factory public factory;
    MockERC20 public usdc;
    MockERC20 public dai;
    
    address public owner = address(this);
    address public creator1 = address(0x1);
    address public creator2 = address(0x2);
    address public user1 = address(0x3);
    
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**6;
    uint256 constant MARKET_FEE = 100 * 10**6;
    
    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        
        // Mint tokens
        usdc.mint(owner, INITIAL_SUPPLY);
        usdc.mint(creator1, INITIAL_SUPPLY);
        usdc.mint(creator2, INITIAL_SUPPLY);
        
        dai.mint(owner, INITIAL_SUPPLY);
        
        // Deploy factory
        factory = new Factory(address(usdc));
        
        // Approve
        vm.prank(creator1);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(creator2);
        usdc.approve(address(factory), type(uint256).max);
    }
    
    // ========== MULTI-COLLATERAL TESTS ==========
    
    function testAddCollateral() public {
        assertFalse(factory.isCollateralSupported(address(dai)), "DAI not supported yet");
        
        factory.addCollateral(address(dai));
        
        assertTrue(factory.isCollateralSupported(address(dai)), "DAI should be supported");
    }
    
    function testCannotAddDuplicateCollateral() public {
        factory.addCollateral(address(dai));
        
        vm.expectRevert("Collateral already supported");
        factory.addCollateral(address(dai));
    }
    
    function testRemoveCollateral() public {
        factory.addCollateral(address(dai));
        assertTrue(factory.isCollateralSupported(address(dai)));
        
        factory.removeCollateral(address(dai));
        
        assertFalse(factory.isCollateralSupported(address(dai)), "DAI should be removed");
    }
    
    function testCannotRemovePrimaryCollateral() public {
        vm.expectRevert("Cannot remove primary collateral");
        factory.removeCollateral(address(usdc));
    }
    
    function testPrimaryCollateralSupportedByDefault() public {
        assertTrue(factory.isCollateralSupported(address(usdc)), "USDC should be supported");
    }
    
    // ========== WHITELIST TESTS ==========
    
    function testWhitelistDisabledByDefault() public {
        // Anyone can create market when whitelist disabled
        vm.prank(creator1);
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        assertEq(factory.getMarketLength(), 1, "Market created");
    }
    
    function testEnableWhitelist() public {
        factory.setWhitelistEnabled(true);
        
        // Non-whitelisted user cannot create market
        vm.prank(creator1);
        vm.expectRevert("Not whitelisted");
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
    }
    
    function testAddToWhitelist() public {
        factory.setWhitelistEnabled(true);
        factory.addToWhitelist(creator1);
        
        // Whitelisted user can create market
        vm.prank(creator1);
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        assertEq(factory.getMarketLength(), 1, "Market created by whitelisted user");
    }
    
    function testRemoveFromWhitelist() public {
        factory.setWhitelistEnabled(true);
        factory.addToWhitelist(creator1);
        factory.removeFromWhitelist(creator1);
        
        vm.prank(creator1);
        vm.expectRevert("Not whitelisted");
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
    }
    
    function testBatchAddToWhitelist() public {
        address[] memory creators = new address[](3);
        creators[0] = creator1;
        creators[1] = creator2;
        creators[2] = user1;
        
        factory.batchAddToWhitelist(creators);
        
        assertTrue(factory.whitelistedCreators(creator1), "Creator1 whitelisted");
        assertTrue(factory.whitelistedCreators(creator2), "Creator2 whitelisted");
        assertTrue(factory.whitelistedCreators(user1), "User1 whitelisted");
    }
    
    // ========== MARKET CATEGORIZATION TESTS ==========
    
    function testSetMarketCategory() public {
        // Create market first
        vm.prank(creator1);
        string[] memory names = new string[](1);
        names[0] = "BTC Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        (address market,) = factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        // Set category
        factory.setMarketCategory(market, "Crypto");
        
        assertEq(factory.marketCategory(market), "Crypto", "Category set");
    }
    
    function testGetMarketsByCategory() public {
        // Create multiple markets in same category
        vm.startPrank(creator1);
        
        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        names[0] = "BTC Market";
        symbols[0] = "BTC";
        (address market1,) = factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        names[0] = "ETH Market";
        symbols[0] = "ETH";
        (address market2,) = factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        vm.stopPrank();
        
        // Categorize
        factory.setMarketCategory(market1, "Crypto");
        factory.setMarketCategory(market2, "Crypto");
        
        address[] memory cryptoMarkets = factory.getMarketsByCategory("Crypto");
        assertEq(cryptoMarkets.length, 2, "Two crypto markets");
    }
    
    function testSetMarketTags() public {
        vm.prank(creator1);
        string[] memory names = new string[](1);
        names[0] = "BTC Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        (address market,) = factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        // Set tags
        string[] memory tags = new string[](3);
        tags[0] = "crypto";
        tags[1] = "bitcoin";
        tags[2] = "price";
        
        factory.setMarketTags(market, tags);
        
        string[] memory marketTags = factory.getMarketTags(market);
        assertEq(marketTags.length, 3, "Three tags set");
        assertEq(marketTags[0], "crypto", "First tag correct");
    }
    
    // ========== CREATOR TRACKING TESTS ==========
    
    function testGetCreatorMarkets() public {
        vm.startPrank(creator1);
        
        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Create first market
        names[0] = "Market 1";
        symbols[0] = "M1";
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        // Create second market
        names[0] = "Market 2";
        symbols[0] = "M2";
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        vm.stopPrank();
        
        address[] memory creatorMarkets = factory.getCreatorMarkets(creator1);
        assertEq(creatorMarkets.length, 2, "Creator has 2 markets");
    }
    
    function testGetCreatorMarketCount() public {
        vm.startPrank(creator1);
        
        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        names[0] = "Market 1";
        symbols[0] = "M1";
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        uint256 count = factory.getCreatorMarketCount(creator1);
        assertEq(count, 1, "Creator market count is 1");
        
        names[0] = "Market 2";
        symbols[0] = "M2";
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        count = factory.getCreatorMarketCount(creator1);
        assertEq(count, 2, "Creator market count is 2");
        
        vm.stopPrank();
    }
    
    // ========== DURATION VALIDATION TESTS ==========
    
    function testSetMinMarketDuration() public {
        uint256 newMin = 2 hours;
        factory.setMinMarketDuration(newMin);
        
        vm.prank(creator1);
        vm.expectRevert("Market duration too short");
        
        string[] memory names = new string[](1);
        names[0] = "Short Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "SHORT";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Try to create market with 1 hour duration
        factory.createMarket(names, symbols, block.timestamp + 1 hours, outcomes);
    }
    
    function testSetMaxMarketDuration() public {
        uint256 newMax = 30 days;
        factory.setMaxMarketDuration(newMax);
        
        vm.prank(creator1);
        vm.expectRevert("Market duration too long");
        
        string[] memory names = new string[](1);
        names[0] = "Long Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "LONG";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Try to create market with 1 year duration
        factory.createMarket(names, symbols, block.timestamp + 365 days, outcomes);
    }
    
    function testMarketDurationValidation() public {
        vm.prank(creator1);
        
        string[] memory names = new string[](1);
        names[0] = "Valid Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "VALID";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Should work with default durations (1 hour to 365 days)
        factory.createMarket(names, symbols, block.timestamp + 30 days, outcomes);
        
        assertEq(factory.getMarketLength(), 1, "Market created");
    }
    
    // ========== PAUSE/UNPAUSE TESTS ==========
    
    function testPauseFactory() public {
        factory.pause();
        
        vm.prank(creator1);
        vm.expectRevert();
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
    }
    
    function testUnpauseFactory() public {
        factory.pause();
        factory.unpause();
        
        vm.prank(creator1);
        
        string[] memory names = new string[](1);
        names[0] = "Test Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        factory.createMarket(names, symbols, block.timestamp + 1 days, outcomes);
        
        assertEq(factory.getMarketLength(), 1, "Market created after unpause");
    }
    
    // ========== INTEGRATION TESTS ==========
    
    function testCompleteMarketCreationFlow() public {
        // 1. Enable whitelist
        factory.setWhitelistEnabled(true);
        
        // 2. Add creator to whitelist
        factory.addToWhitelist(creator1);
        
        // 3. Create market
        vm.prank(creator1);
        string[] memory names = new string[](1);
        names[0] = "BTC Price Market";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC";
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        (address market,) = factory.createMarket(names, symbols, block.timestamp + 30 days, outcomes);
        
        // 4. Set category and tags
        factory.setMarketCategory(market, "Crypto");
        string[] memory tags = new string[](2);
        tags[0] = "bitcoin";
        tags[1] = "price";
        factory.setMarketTags(market, tags);
        
        // 5. Verify
        assertEq(factory.getCreatorMarketCount(creator1), 1, "Creator has 1 market");
        assertEq(factory.marketCategory(market), "Crypto", "Category set");
        assertEq(factory.getMarketTags(market).length, 2, "Tags set");
        
        address[] memory cryptoMarkets = factory.getMarketsByCategory("Crypto");
        assertEq(cryptoMarkets.length, 1, "One crypto market");
    }
}

