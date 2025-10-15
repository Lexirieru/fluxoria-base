// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
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

contract ConditionalTokensTest is Test {
    ConditionalTokens public conditionalTokens;
    MockERC20 public collateralToken;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10**6; // 1M USDC
    uint256 public constant USER_BALANCE = 10000 * 10**6; // 10K USDC per user
    
    function setUp() public {
        // Deploy mock collateral token
        collateralToken = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint tokens to users
        collateralToken.mint(owner, INITIAL_SUPPLY);
        collateralToken.mint(user1, USER_BALANCE);
        collateralToken.mint(user2, USER_BALANCE);
        collateralToken.mint(user3, USER_BALANCE);
        
        // Deploy conditional tokens contract
        vm.prank(owner);
        conditionalTokens = new ConditionalTokens(address(collateralToken));
        
        // Set mint fee to 0 for backward compatibility with existing tests
        vm.prank(owner);
        conditionalTokens.setMintFee(0);
        
        // Users approve conditional tokens contract
        vm.prank(user1);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
        
        vm.prank(user2);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
        
        vm.prank(user3);
        collateralToken.approve(address(conditionalTokens), USER_BALANCE);
    }
    
    function testCreateMarket() public {
        string memory question = "Will Bitcoin reach $100k by 2024?";
        string memory description = "Prediction market for Bitcoin price";
        uint256 resolutionTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(owner);
        uint256 marketId = conditionalTokens.createMarket(
            question,
            description,
            resolutionTime,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        assertEq(marketId, 0);
        
        ConditionalTokens.Market memory market = conditionalTokens.getMarket(marketId);
        assertEq(market.question, question);
        assertEq(market.description, description);
        assertEq(market.resolutionTime, resolutionTime);
        assertEq(uint256(market.outcomeType), uint256(ConditionalTokens.OutcomeType.Binary));
        assertEq(market.outcomes.length, 2);
        assertEq(market.outcomes[0], "Yes");
        assertEq(market.outcomes[1], "No");
        assertEq(market.creator, owner);
        assertFalse(market.isResolved);
    }
    
    function testCreateMarketFails() public {
        string memory question = "";
        string memory description = "Test";
        uint256 resolutionTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        // Test empty question
        vm.prank(owner);
        vm.expectRevert("Question cannot be empty");
        conditionalTokens.createMarket(
            question,
            description,
            resolutionTime,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Test past resolution time
        question = "Test question";
        resolutionTime = block.timestamp - 1;
        
        vm.prank(owner);
        vm.expectRevert("Resolution time must be in future");
        conditionalTokens.createMarket(
            question,
            description,
            resolutionTime,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
        
        // Test insufficient outcomes
        resolutionTime = block.timestamp + 365 days;
        string[] memory singleOutcome = new string[](1);
        singleOutcome[0] = "Yes";
        
        vm.prank(owner);
        vm.expectRevert("Must have at least 2 outcomes");
        conditionalTokens.createMarket(
            question,
            description,
            resolutionTime,
            ConditionalTokens.OutcomeType.Binary,
            singleOutcome
        );
    }
    
    function testMintTokens() public {
        // Create market first
        uint256 marketId = _createTestMarket();
        
        uint256 amount = 1000 * 10**6; // 1000 USDC
        uint256 outcome = 0; // "Yes"
        
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, outcome, amount);
        
        // Check user's outcome balance
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user1, outcome), amount);
        
        // Check market total collateral
        ConditionalTokens.Market memory market = conditionalTokens.getMarket(marketId);
        assertEq(market.totalCollateral, amount);
        
        // Check collateral token balance
        assertEq(collateralToken.balanceOf(address(conditionalTokens)), amount);
        assertEq(collateralToken.balanceOf(user1), USER_BALANCE - amount);
    }
    
    function testMintTokensFails() public {
        uint256 marketId = _createTestMarket();
        uint256 amount = 1000 * 10**6;
        uint256 outcome = 0;
        
        // Test non-existent market
        vm.prank(user1);
        vm.expectRevert("Market does not exist");
        conditionalTokens.mintTokens(999, outcome, amount);
        
        // Test invalid outcome
        vm.prank(user1);
        vm.expectRevert("Invalid outcome");
        conditionalTokens.mintTokens(marketId, 2, amount);
        
        // Test zero amount
        vm.prank(user1);
        vm.expectRevert("Amount must be positive");
        conditionalTokens.mintTokens(marketId, outcome, 0);
        
        // Test insufficient allowance
        vm.prank(user1);
        vm.expectRevert("ERC20: insufficient allowance");
        conditionalTokens.mintTokens(marketId, outcome, USER_BALANCE + 1);
    }
    
    function testBurnTokens() public {
        // Create market and mint tokens
        uint256 marketId = _createTestMarket();
        uint256 amount = 1000 * 10**6;
        uint256 outcome = 0;
        
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, outcome, amount);
        
        uint256 burnAmount = 500 * 10**6;
        
        vm.prank(user1);
        conditionalTokens.burnTokens(marketId, outcome, burnAmount);
        
        // Check user's outcome balance
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user1, outcome), amount - burnAmount);
        
        // Check market total collateral
        ConditionalTokens.Market memory market = conditionalTokens.getMarket(marketId);
        assertEq(market.totalCollateral, amount - burnAmount);
        
        // Check collateral token balance
        assertEq(collateralToken.balanceOf(address(conditionalTokens)), amount - burnAmount);
        assertEq(collateralToken.balanceOf(user1), USER_BALANCE - amount + burnAmount);
    }
    
    function testBurnTokensFails() public {
        uint256 marketId = _createTestMarket();
        uint256 amount = 1000 * 10**6;
        uint256 outcome = 0;
        
        // Test insufficient balance
        vm.prank(user1);
        vm.expectRevert("Insufficient token balance");
        conditionalTokens.burnTokens(marketId, outcome, amount);
        
        // Mint tokens first
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, outcome, amount);
        
        // Test burning more than balance
        vm.prank(user1);
        vm.expectRevert("Insufficient token balance");
        conditionalTokens.burnTokens(marketId, outcome, amount + 1);
    }
    
    function testResolveMarket() public {
        uint256 marketId = _createTestMarket();
        uint256 winningOutcome = 0;
        
        // Test resolution before time
        vm.prank(owner);
        vm.expectRevert("Market not ready for resolution");
        conditionalTokens.resolveMarket(marketId, winningOutcome);
        
        // Fast forward to resolution time
        vm.warp(block.timestamp + 365 days + 1);
        
        vm.prank(owner);
        conditionalTokens.resolveMarket(marketId, winningOutcome);
        
        ConditionalTokens.Market memory market = conditionalTokens.getMarket(marketId);
        assertEq(uint256(market.state), uint256(ConditionalTokens.MarketState.Resolved));
        assertEq(market.winningOutcome, winningOutcome);
        assertTrue(market.isResolved);
    }
    
    function testResolveMarketFails() public {
        uint256 marketId = _createTestMarket();
        
        // Test non-owner
        vm.prank(user1);
        vm.expectRevert();
        conditionalTokens.resolveMarket(marketId, 0);
        
        // Test non-existent market
        vm.prank(owner);
        vm.expectRevert("Market does not exist");
        conditionalTokens.resolveMarket(999, 0);
        
        // Test invalid winning outcome
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(owner);
        vm.expectRevert("Invalid winning outcome");
        conditionalTokens.resolveMarket(marketId, 2);
    }
    
    function testRedeemTokens() public {
        uint256 marketId = _createTestMarket();
        uint256 amount = 1000 * 10**6;
        uint256 outcome = 0;
        
        // Mint tokens
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, outcome, amount);
        
        // Resolve market
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(owner);
        conditionalTokens.resolveMarket(marketId, outcome);
        
        // Redeem tokens
        vm.prank(user1);
        conditionalTokens.redeemTokens(marketId, outcome);
        
        // Check user's outcome balance is zero
        assertEq(conditionalTokens.getOutcomeBalance(marketId, user1, outcome), 0);
        
        // Check user received collateral
        assertEq(collateralToken.balanceOf(user1), USER_BALANCE);
    }
    
    function testRedeemTokensFails() public {
        uint256 marketId = _createTestMarket();
        uint256 amount = 1000 * 10**6;
        uint256 outcome = 0;
        
        // Test redeeming before resolution
        vm.prank(user1);
        vm.expectRevert("Market not resolved");
        conditionalTokens.redeemTokens(marketId, outcome);
        
        // Mint tokens and resolve
        vm.prank(user1);
        conditionalTokens.mintTokens(marketId, outcome, amount);
        
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(owner);
        conditionalTokens.resolveMarket(marketId, outcome);
        
        // Test redeeming wrong outcome
        vm.prank(user1);
        vm.expectRevert("Not the winning outcome");
        conditionalTokens.redeemTokens(marketId, 1);
        
        // Test redeeming with no tokens
        vm.prank(user2);
        vm.expectRevert("No tokens to redeem");
        conditionalTokens.redeemTokens(marketId, outcome);
    }
    
    function testMultipleMarkets() public {
        // Create multiple markets
        uint256 market1 = _createTestMarket();
        uint256 market2 = _createTestMarket();
        
        assertEq(market1, 0);
        assertEq(market2, 1);
        assertEq(conditionalTokens.getMarketCount(), 2);
        
        // Test market isolation
        vm.prank(user1);
        conditionalTokens.mintTokens(market1, 0, 1000 * 10**6);
        
        vm.prank(user2);
        conditionalTokens.mintTokens(market2, 0, 2000 * 10**6);
        
        assertEq(conditionalTokens.getOutcomeBalance(market1, user1, 0), 1000 * 10**6);
        assertEq(conditionalTokens.getOutcomeBalance(market2, user1, 0), 0);
        assertEq(conditionalTokens.getOutcomeBalance(market2, user2, 0), 2000 * 10**6);
    }
    
    function testMarketStates() public {
        uint256 marketId = _createTestMarket();
        
        // Test initial state
        assertTrue(conditionalTokens.isMarketActive(marketId));
        
        // Resolve market
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(owner);
        conditionalTokens.resolveMarket(marketId, 0);
        
        // Test resolved state
        assertFalse(conditionalTokens.isMarketActive(marketId));
    }
    
    function _createTestMarket() internal returns (uint256) {
        string memory question = "Will Bitcoin reach $100k by 2024?";
        string memory description = "Prediction market for Bitcoin price";
        uint256 resolutionTime = block.timestamp + 365 days;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        
        vm.prank(owner);
        return conditionalTokens.createMarket(
            question,
            description,
            resolutionTime,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );
    }
}
