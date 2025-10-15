// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Factory} from "../src/Factory.sol";
import {Fluxoria} from "../src/Fluxoria.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token for testing
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
    
    function name() public view returns (string memory) {
        return _name;
    }
    
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    
    function decimals() public view returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
    
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
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    
    function mint(address to, uint256 amount) public {
        require(to != address(0), "ERC20: mint to the zero address");
        
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
    }
}

contract FactoryTest is Test {
    Factory public factory;
    MockERC20 public collateralToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**6; // 1M USDC
    uint256 public constant USER_BALANCE = 10000 * 10**6; // 10K USDC per user
    uint256 public constant MARKET_CREATION_FEE = 100 * 10**6; // 100 USDC
    
    function setUp() public {
        // Deploy mock collateral token
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens to users
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        
        // Deploy factory
        vm.prank(owner);
        factory = new Factory(address(collateralToken));
        
        // Users approve factory for market creation fee
        vm.prank(user1);
        collateralToken.approve(address(factory), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(factory), USER_BALANCE);
    }
    
    function testInitialization() public {
        assertEq(factory.owner(), owner);
        assertEq(factory.COLLATERAL_TOKEN(), address(collateralToken));
        assertEq(factory.marketCreationFee(), MARKET_CREATION_FEE);
        assertEq(factory.getMarketLength(), 0);
    }
    
    function testCreateMarket() public {
        string[] memory names = new string[](1);
        names[0] = "Will Bitcoin reach $100k by 2024?";
        string[] memory symbols = new string[](1);
        symbols[0] = "BTC-100K";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        vm.prank(user1);
        (address market, address conditionalTokens) = factory.createMarket(
            names,
            symbols,
            expiredTime,
            outcomes
        );
        
        // Check market was created
        assertTrue(market != address(0));
        assertTrue(conditionalTokens != address(0));
        assertTrue(factory.isMarket(market));
        assertEq(factory.getMarketLength(), 1);
        
        // Check market details
        Fluxoria marketContract = Fluxoria(market);
        assertEq(marketContract.owner(), user1); // Ownership is transferred to the creator
        
        // Check conditional tokens contract
        ConditionalTokens ctContract = ConditionalTokens(conditionalTokens);
        assertEq(ctContract.owner(), market); // Owned by the Fluxoria market contract
        
        // Check market creation fee was paid
        assertEq(collateralToken.balanceOf(user1), initialBalance - MARKET_CREATION_FEE);
        assertEq(collateralToken.balanceOf(address(factory)), MARKET_CREATION_FEE);

        // Check mappings
        assertEq(factory.marketToConditionalTokens(market), conditionalTokens);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens), market);

        // Check order book
        address orderBook = address(marketContract.orderBook());
        assertTrue(orderBook != address(0));
        assertEq(factory.marketToOrderBook(market), orderBook);
        assertEq(factory.orderBookToMarket(orderBook), market);
    }
    
    function testCreateMarketFails() public {
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Test empty question
        string[] memory emptyNames = new string[](0);
        vm.expectRevert("Question cannot be empty");
        vm.prank(user1);
        factory.createMarket(emptyNames, symbols, expiredTime, outcomes);
        
        // Test empty description
        string[] memory emptySymbols = new string[](0);
        vm.expectRevert("Description cannot be empty");
        vm.prank(user1);
        factory.createMarket(names, emptySymbols, expiredTime, outcomes);
        
        // Test insufficient outcomes
        string[] memory singleOutcome = new string[](1);
        singleOutcome[0] = "Yes";
        vm.expectRevert("Must have at least 2 outcomes");
        vm.prank(user1);
        factory.createMarket(names, symbols, expiredTime, singleOutcome);

        // Test past expiration time
        uint256 pastTime = block.timestamp - 1;
        vm.expectRevert("Resolution time must be in future");
        vm.prank(user1);
        factory.createMarket(names, symbols, pastTime, outcomes);
    }
    
    function testCreateMarketWithCustomTokens() public {
        string memory question = "Will Ethereum reach $5000?";
        string memory description = "ETH-5000";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        vm.prank(user1);
        (address market, address conditionalTokens) = factory.createMarketWithCustomTokens(
            question,
            description,
            expiredTime,
            outcomes,
            ConditionalTokens.OutcomeType.Binary
        );
        
        // Check market was created
        assertTrue(market != address(0));
        assertTrue(conditionalTokens != address(0));
        assertTrue(factory.isMarket(market));
        assertEq(factory.getMarketLength(), 1);
        
        // Check market details
        Fluxoria marketContract = Fluxoria(market);
        assertEq(marketContract.owner(), user1); // Ownership is transferred to the creator
        
        // Check conditional tokens contract
        ConditionalTokens ctContract = ConditionalTokens(conditionalTokens);
        assertEq(ctContract.owner(), address(factory)); // This one is created by Factory, not Fluxoria
        
        // Check market creation fee was paid
        assertEq(collateralToken.balanceOf(user1), initialBalance - MARKET_CREATION_FEE);
        
        // Check mappings
        assertEq(factory.marketToConditionalTokens(market), conditionalTokens);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens), market);
        
        // Check order book
        address orderBook = address(marketContract.orderBook());
        assertTrue(orderBook != address(0));
        assertEq(factory.marketToOrderBook(market), orderBook);
        assertEq(factory.orderBookToMarket(orderBook), market);
    }
    
    function testCreateMarketWithCustomTokensFails() public {
        string memory question = "Test Question";
        string memory description = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Test empty question
        vm.prank(user1);
        vm.expectRevert("Question cannot be empty");
        factory.createMarketWithCustomTokens("", description, expiredTime, outcomes, ConditionalTokens.OutcomeType.Binary);
        
        // Test empty description
        vm.prank(user1);
        vm.expectRevert("Description cannot be empty");
        factory.createMarketWithCustomTokens(question, "", expiredTime, outcomes, ConditionalTokens.OutcomeType.Binary);
        
        // Test insufficient outcomes
        string[] memory singleOutcome = new string[](1);
        singleOutcome[0] = "Yes";
        vm.prank(user1);
        vm.expectRevert("Must have at least 2 outcomes");
        factory.createMarketWithCustomTokens(question, description, expiredTime, singleOutcome, ConditionalTokens.OutcomeType.Binary);
        
        // Test past expiration time
        uint256 pastTime = block.timestamp - 1;
        vm.prank(user1);
        vm.expectRevert("Resolution time must be in future");
        factory.createMarketWithCustomTokens(question, description, pastTime, outcomes, ConditionalTokens.OutcomeType.Binary);
    }
    
    function testMultipleMarkets() public {
        // Create first market
        string[] memory names1 = new string[](1);
        names1[0] = "Will Bitcoin reach $100k?";
        string[] memory symbols1 = new string[](1);
        symbols1[0] = "BTC-100K";
        uint256 expiredTime1 = block.timestamp + 365 days;
        string[] memory outcomes1 = new string[](2);
        outcomes1[0] = "Yes";
        outcomes1[1] = "No";
        
        vm.prank(user1);
        (address market1, address conditionalTokens1) = factory.createMarket(
            names1,
            symbols1,
            expiredTime1,
            outcomes1
        );
        
        // Create second market
        string[] memory names2 = new string[](1);
        names2[0] = "Will Ethereum reach $5000?";
        string[] memory symbols2 = new string[](1);
        symbols2[0] = "ETH-5000";
        uint256 expiredTime2 = block.timestamp + 200 days;
        string[] memory outcomes2 = new string[](2);
        outcomes2[0] = "Yes";
        outcomes2[1] = "No";
        
        vm.prank(user2);
        (address market2, address conditionalTokens2) = factory.createMarket(
            names2,
            symbols2,
            expiredTime2,
            outcomes2
        );
        
        // Check both markets exist
        assertTrue(factory.isMarket(market1));
        assertTrue(factory.isMarket(market2));
        assertEq(factory.getMarketLength(), 2);
        
        // Check markets are different
        assertTrue(market1 != market2);
        assertTrue(conditionalTokens1 != conditionalTokens2);
        
        // Check mappings
        assertEq(factory.marketToConditionalTokens(market1), conditionalTokens1);
        assertEq(factory.marketToConditionalTokens(market2), conditionalTokens2);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens1), market1);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens2), market2);
        
        // Check order books
        address orderBook1 = factory.marketToOrderBook(market1);
        address orderBook2 = factory.marketToOrderBook(market2);
        assertTrue(orderBook1 != address(0));
        assertTrue(orderBook2 != address(0));
        assertTrue(orderBook1 != orderBook2);
    }
    
    function testGetAllMarkets() public {
        // Create multiple markets
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        (address market1,) = factory.createMarket(names, symbols, expiredTime, outcomes);
        
        vm.prank(user2);
        (address market2,) = factory.createMarket(names, symbols, expiredTime, outcomes);
        
        // Get all markets
        address[] memory allMarkets = factory.getAllMarkets();
        assertEq(allMarkets.length, 2);
        assertEq(allMarkets[0], market1);
        assertEq(allMarkets[1], market2);
    }
    
    function testSetMarketCreationFee() public {
        uint256 newFee = 200 * 10**6; // 200 USDC
        
        vm.prank(owner);
        factory.setMarketCreationFee(newFee);
        
        assertEq(factory.marketCreationFee(), newFee);
    }
    
    function testSetMarketCreationFeeFails() public {
        uint256 newFee = 200 * 10**6;
        
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        factory.setMarketCreationFee(newFee);
    }
    
    function testWithdrawFees() public {
        // Create a market to generate fees
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        factory.createMarket(names, symbols, expiredTime, outcomes);
        
        uint256 fees = factory.getTotalFees();
        assertEq(fees, MARKET_CREATION_FEE);
        
        uint256 ownerBalance = collateralToken.balanceOf(owner);
        
        // Withdraw fees
        vm.prank(owner);
        factory.withdrawFees();
        
        // Check owner received fees
        assertEq(collateralToken.balanceOf(owner), ownerBalance + fees);
        assertEq(factory.getTotalFees(), 0);
    }
    
    function testWithdrawFeesFails() public {
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        factory.withdrawFees();
        
        // Test no fees to withdraw
        vm.prank(owner);
        vm.expectRevert("No fees to withdraw");
        factory.withdrawFees();
    }
    
    function testGetTotalFees() public {
        // Initially no fees
        assertEq(factory.getTotalFees(), 0);
        
        // Create a market to generate fees
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        factory.createMarket(names, symbols, expiredTime, outcomes);
        
        // Check fees were collected
        assertEq(factory.getTotalFees(), MARKET_CREATION_FEE);
    }
    
    function testMarketCreationFeeZero() public {
        // Set fee to zero
        vm.prank(owner);
        factory.setMarketCreationFee(0);
        
        // Create market without fee
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        uint256 initialBalance = collateralToken.balanceOf(user1);
        
        vm.prank(user1);
        (address market,) = factory.createMarket(names, symbols, expiredTime, outcomes);
        
        // Check market was created
        assertTrue(market != address(0));
        assertTrue(factory.isMarket(market));
        
        // Check no fee was paid
        assertEq(collateralToken.balanceOf(user1), initialBalance);
        assertEq(factory.getTotalFees(), 0);
    }
    
    function testContractAddresses() public {
        // Create a market
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        (address market, address conditionalTokens) = factory.createMarket(
            names,
            symbols,
            expiredTime,
            outcomes
        );
        
        // Check contract addresses
        assertEq(factory.getConditionalTokens(market), conditionalTokens);
        assertEq(factory.getMarket(conditionalTokens), market);
        
        // Check order book addresses
        Fluxoria marketContract = Fluxoria(market);
        address orderBook = address(marketContract.orderBook());
        
        assertEq(factory.getOrderBook(market), orderBook);
        assertEq(factory.getMarketFromOrderBook(orderBook), market);
    }
    
    function testMarketIsolation() public {
        // Create two markets
        string[] memory names = new string[](1);
        names[0] = "Test Question";
        string[] memory symbols = new string[](1);
        symbols[0] = "TEST";
        uint256 expiredTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(user1);
        (address market1, address conditionalTokens1) = factory.createMarket(
            names,
            symbols,
            expiredTime,
            outcomes
        );
        
        vm.prank(user2);
        (address market2, address conditionalTokens2) = factory.createMarket(
            names,
            symbols,
            expiredTime,
            outcomes
        );
        
        // Check markets are isolated
        assertTrue(market1 != market2);
        assertTrue(conditionalTokens1 != conditionalTokens2);
        
        // Check mappings are correct
        assertEq(factory.marketToConditionalTokens(market1), conditionalTokens1);
        assertEq(factory.marketToConditionalTokens(market2), conditionalTokens2);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens1), market1);
        assertEq(factory.conditionalTokensToMarket(conditionalTokens2), market2);
        
        // Check order books are different
        address orderBook1 = factory.getOrderBook(market1);
        address orderBook2 = factory.getOrderBook(market2);
        assertTrue(orderBook1 != orderBook2);
    }
}
