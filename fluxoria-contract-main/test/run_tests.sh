#!/bin/bash

# Test runner script for Fluxoria contracts
echo "🚀 Running Fluxoria Contract Tests"
echo "=================================="

# Run individual contract tests
echo "📋 Testing ConditionalTokens contract..."
forge test --match-contract ConditionalTokensTest -vv

echo "📋 Testing Fluxoria contract..."
forge test --match-contract FluxoriaTest -vv

echo "📋 Testing OrderBook contract..."
forge test --match-contract OrderBookTest -vv

echo "📋 Testing Factory contract..."
forge test --match-contract FactoryTest -vv

echo "📋 Testing Integration tests..."
forge test --match-contract IntegrationTest -vv

forge test --match-contract FluxoriaEnhancementTest -vv

# Run all tests
echo "📋 Running all tests..."
forge test -vv

echo "✅ All tests completed!"
