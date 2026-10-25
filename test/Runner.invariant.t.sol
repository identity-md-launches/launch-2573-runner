// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Runner} from "../src/Runner.sol";

/// @dev A closed set of actors and a separate model for stateful ERC-20 accounting.
contract RunnerHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    Runner public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor() {
        actors[0] = makeAddr("invariant alice");
        actors[1] = makeAddr("invariant bob");
        actors[2] = makeAddr("invariant carol");
        actors[3] = makeAddr("invariant dave");
        token = new Runner();
        assertTrue(token.transfer(actors[0], SUPPLY));
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, bool infinite) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = infinite ? type(uint256).max : bound(rawAmount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) public {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from];
        uint256 amount = bound(rawAmount, 0, approved < available ? approved : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

contract RunnerInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    RunnerHandler internal handler;
    Runner internal token;

    function setUp() public {
        handler = new RunnerHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RunnerHandler.transfer.selector;
        selectors[1] = RunnerHandler.approve.selector;
        selectors[2] = RunnerHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_TotalSupplyAndBalancesAreConserved() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_AllowancesMatchApprovalsAndSpending() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
