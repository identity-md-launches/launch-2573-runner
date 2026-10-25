// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Runner} from "../src/Runner.sol";

/// @dev Deploys the token through CREATE2 and distributes in the same call, as a launch factory does
/// in one transaction.
contract RunnerLaunchHarness {
    function launch(bytes32 salt, address distributor, address pool, address remainder)
        external
        returns (Runner token)
    {
        token = new Runner{salt: salt}();
        uint256 supply = token.totalSupply();
        require(token.balanceOf(address(this)) == supply, "supply not minted to factory");
        require(token.transfer(distributor, supply / 10));
        require(token.transfer(pool, supply * 8 / 10));
        require(token.transfer(remainder, token.balanceOf(address(this))));
    }
}

/// @dev Drives both successful and failing calls. Every failing call must revert and leave the
/// model untouched; the invariants then compare the model against the token.
contract RunnerFailurePathHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    Runner public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public expectedFailures;
    uint256 public observedFailures;

    constructor() {
        actors[0] = makeAddr("fp alice");
        actors[1] = makeAddr("fp bob");
        actors[2] = makeAddr("fp carol");
        actors[3] = makeAddr("fp dave");
        actors[4] = makeAddr("fp erin");
        token = new Runner();
        // Spread the supply so several actors hold balances from the start.
        uint256 share = SUPPLY / 5;
        for (uint256 i; i < 4; ++i) {
            require(token.transfer(actors[i], share));
            expectedBalance[actors[i]] = share;
        }
        uint256 rest = SUPPLY - share * 4;
        require(token.transfer(actors[4], rest));
        expectedBalance[actors[4]] = rest;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        require(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 rawExcess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(rawExcess, 1, type(uint256).max - balance);
        expectedFailures++;
        vm.prank(from);
        try token.transfer(to, amount) returns (bool) {}
        catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
                    ),
                "unexpected revert reason"
            );
            observedFailures++;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        expectedFailures++;
        vm.prank(from);
        try token.transfer(address(0), amount) returns (bool) {}
        catch {
            observedFailures++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = infinite ? type(uint256).max : bound(rawAmount, 0, SUPPLY);
        vm.prank(owner);
        require(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from];
        uint256 amount = bound(rawAmount, 0, approved < available ? approved : available);
        vm.prank(spender);
        require(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    /// @dev Spends more than approved. Skipped (no call) when the allowance is infinite.
    function transferFromOverAllowance(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawExcess)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 approved = expectedAllowance[from][spender];
        if (approved == type(uint256).max) return;
        uint256 amount = approved + bound(rawExcess, 1, type(uint256).max - approved);
        expectedFailures++;
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool) {}
        catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount
                        )
                    ),
                "unexpected revert reason"
            );
            observedFailures++;
        }
    }

    /// @dev Within allowance but above balance: must revert and must not consume the allowance.
    function transferFromOverBalance(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawExcess)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(rawExcess, 1, SUPPLY);
        vm.prank(from);
        require(token.approve(spender, amount));
        expectedAllowance[from][spender] = amount;
        expectedFailures++;
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool) {}
        catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
                    ),
                "unexpected revert reason"
            );
            observedFailures++;
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        expectedFailures++;
        vm.prank(owner);
        try token.approve(address(0), rawAmount) returns (bool) {}
        catch {
            observedFailures++;
        }
    }
}

contract RunnerFailurePathInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    RunnerFailurePathHandler internal handler;
    Runner internal token;

    function setUp() public {
        handler = new RunnerFailurePathHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = RunnerFailurePathHandler.transfer.selector;
        selectors[1] = RunnerFailurePathHandler.transferTooMuch.selector;
        selectors[2] = RunnerFailurePathHandler.transferToZero.selector;
        selectors[3] = RunnerFailurePathHandler.approve.selector;
        selectors[4] = RunnerFailurePathHandler.transferFrom.selector;
        selectors[5] = RunnerFailurePathHandler.transferFromOverAllowance.selector;
        selectors[6] = RunnerFailurePathHandler.transferFromOverBalance.selector;
        selectors[7] = RunnerFailurePathHandler.approveZeroSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_SupplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_AllowancesMatchModel() public view {
        for (uint256 i; i < 5; ++i) {
            for (uint256 j; j < 5; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(handler.actors(i), address(0)), 0);
        }
    }

    /// @dev Every call that must fail did fail: none of them silently succeeded.
    function invariant_EveryInvalidCallReverted() public view {
        assertEq(handler.observedFailures(), handler.expectedFailures());
    }
}

contract RunnerAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    Runner internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        alice = makeAddr("adv alice");
        bob = makeAddr("adv bob");
        spender = makeAddr("adv spender");
        token = new Runner();
    }

    function test_LaunchInOneCallDeliversExactShares() public {
        RunnerLaunchHarness factory = new RunnerLaunchHarness();
        address distributor = makeAddr("adv distributor");
        address pool = makeAddr("adv pool");
        address remainder = makeAddr("adv remainder");
        bytes32 salt = bytes32(uint256(7));
        address predicted = vm.computeCreate2Address(salt, keccak256(type(Runner).creationCode), address(factory));

        Runner launched = factory.launch(salt, distributor, pool, remainder);

        assertEq(address(launched), predicted);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(distributor), 100_000_000 ether);
        assertEq(launched.balanceOf(pool), 800_000_000 ether);
        assertEq(launched.balanceOf(remainder), 100_000_000 ether);
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_SameSaltCannotRedeployOverExistingToken() public {
        RunnerLaunchHarness factory = new RunnerLaunchHarness();
        bytes32 salt = bytes32(uint256(1));
        factory.launch(salt, alice, bob, spender);
        vm.expectRevert();
        factory.launch(salt, alice, bob, spender);
    }

    function test_SeparateDeploymentsHaveIndependentLedgers() public {
        Runner other = new Runner();
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 5 ether);
    }

    function test_OneWeiMovesExactly() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_SupplyPlusOneReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_MaxUintTransferReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_AllowanceOneBelowMaxIsDecremented() public {
        uint256 allowance = type(uint256).max - 1;
        assertTrue(token.approve(spender, allowance));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), allowance - 1);
    }

    function test_SameTransferFromTwiceExhaustsAllowance() public {
        assertTrue(token.approve(spender, 10 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 10 ether));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_SelfApprovalDoesNotBypassAllowanceCheck() public {
        // An owner calling transferFrom on itself still needs an allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertTrue(token.approve(address(this), 1));
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
    }

    function test_TokenAddressCanReceiveButNotSpendWithoutCall() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_UnknownSelectorAndCalldataRevert() public {
        (bool ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        (ok,) = address(token).call(hex"");
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveOverwritesRegardlessOfPrior(uint256 first, uint256 second) public {
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ThirdPartyCannotMoveFundsWithoutAllowance(address caller, uint256 amount) public {
        vm.assume(caller != alice);
        amount = bound(amount, 1, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, amount));
        vm.prank(caller);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedTransferLeavesStateUnchanged(uint256 held, uint256 excess, address to) public {
        vm.assume(to != address(0));
        held = bound(held, 0, SUPPLY);
        assertTrue(token.transfer(alice, held));
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        uint256 toBefore = token.balanceOf(to);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(to, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TransferFromSplitsAllowanceExactly(uint256 allowance, uint256 a, uint256 b) public {
        allowance = bound(allowance, 0, SUPPLY);
        a = bound(a, 0, allowance);
        b = bound(b, 0, allowance - a);
        assertTrue(token.approve(spender, allowance));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, a));
        assertTrue(token.transferFrom(address(this), bob, b));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), allowance - a - b);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(address(this)), SUPPLY);
    }
}
