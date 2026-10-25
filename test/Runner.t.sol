// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Runner} from "../src/Runner.sol";

/// @dev Test-only factory; exercises the same immediate-deployer semantics as a launch factory.
contract RunnerFactoryHarness {
    function deploy(bytes32 salt) external returns (Runner) {
        return new Runner{salt: salt}();
    }

    function move(Runner token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount));
    }
}

contract RunnerTest is Test {
    // Independent expected value: do not derive expectations from the contract under test.
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    Runner internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new Runner();
    }

    function test_MetadataAndEntireSupply() public view {
        assertEq(token.name(), "Runner");
        assertEq(token.symbol(), "RUNNER");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        Runner fresh = new Runner();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_EntireSupplyGoesToImmediateDeployer() public {
        vm.prank(alice);
        Runner fresh = new Runner();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_FactoryDeploymentAndLaunchTransfersArriveWhole() public {
        RunnerFactoryHarness factory = new RunnerFactoryHarness();
        Runner fresh = factory.deploy(keccak256("Runner launch test"));
        address distributor = makeAddr("test distributor");
        address pool = makeAddr("test pool custody");
        address remainder = makeAddr("test remainder recipient");

        assertEq(fresh.balanceOf(address(factory)), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
        factory.move(fresh, distributor, SUPPLY / 10);
        factory.move(fresh, pool, SUPPLY * 8 / 10);
        factory.move(fresh, remainder, SUPPLY / 10);
        assertEq(fresh.balanceOf(address(factory)), 0);
        assertEq(fresh.balanceOf(distributor), SUPPLY / 10);
        assertEq(fresh.balanceOf(pool), SUPPLY * 8 / 10);
        assertEq(fresh.balanceOf(remainder), SUPPLY / 10);

        vm.prank(distributor);
        assertTrue(fresh.transfer(alice, SUPPLY / 10));
        assertEq(fresh.balanceOf(distributor), 0);
        assertEq(fresh.balanceOf(alice), SUPPLY / 10);
        vm.prank(pool);
        assertTrue(fresh.transfer(bob, 1 ether));
        vm.prank(bob);
        assertTrue(fresh.transfer(pool, 1 ether));
        assertEq(fresh.balanceOf(bob), 0);
        assertEq(fresh.balanceOf(pool), SUPPLY * 8 / 10);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123 ether);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireBalance() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InsufficientBalanceRevertsAtomically() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventAndDoesNotMoveTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 100 ether);
        assertTrue(token.approve(spender, 100 ether));
        assertEq(token.allowance(address(this), spender), 100 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_ApprovalReplacesExistingValueAndCanBeRevoked() public {
        assertTrue(token.approve(spender, 100 ether));
        assertTrue(token.approve(spender, 2 ether));
        assertEq(token.allowance(address(this), spender), 2 ether);
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1 ether);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_ApprovalsAreIsolatedByOwnerAndSpender() public {
        assertTrue(token.approve(spender, 3 ether));
        vm.prank(alice);
        assertTrue(token.approve(spender, 7 ether));
        assertEq(token.allowance(address(this), spender), 3 ether);
        assertEq(token.allowance(alice, spender), 7 ether);
        assertEq(token.allowance(address(this), bob), 0);
    }

    function test_TransferFromSpendsOnlyApprovedAmountAndEmitsTransfer() public {
        assertTrue(token.approve(spender, 100 ether));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 40 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40 ether));
        assertEq(token.allowance(address(this), spender), 60 ether);
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 60 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, SUPPLY - 1 ether));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromWithoutAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_DeployerCannotSpendAnotherHoldersBalanceWithoutApproval() public {
        assertTrue(token.transfer(alice, 10 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromToSelfSpendsAllowanceWithoutChangingBalance() public {
        assertTrue(token.approve(spender, 10 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 10 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromZeroAmountNeedsNoPriorApproval() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromInsufficientBalanceRestoresAllowance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 100 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 100 ether);
        assertEq(token.allowance(alice, spender), 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromZeroRecipientRestoresAllowance() public {
        assertTrue(token.approve(spender, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromZeroSourceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoMintBurnOwnershipFreezeOrUpgradeEntryPoints() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[5] = abi.encodeWithSignature("owner()");
        calls[6] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[7] = abi.encodeWithSignature("pause()");
        calls[8] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[9] = abi.encodeWithSignature("initialize(address)", alice);
        calls[10] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[11] = abi.encodeWithSignature("seize(address)", alice);

        assertTrue(token.transfer(alice, 10 ether));
        for (uint256 i; i < calls.length; ++i) {
            (bool fromDeployer,) = address(token).call(calls[i]);
            assertFalse(fromDeployer);
            vm.prank(bob);
            (bool fromStranger,) = address(token).call(calls[i]);
            assertFalse(fromStranger);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 10 ether);
            assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_DirectNativeCurrencyPaymentReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, 1 ether);
    }

    function testFuzz_TransferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_ApproveAndDelegatedTransfer(uint256 allowance, uint256 amount) public {
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        assertTrue(token.approve(spender, allowance));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(
            token.allowance(address(this), spender), allowance == type(uint256).max ? allowance : allowance - amount
        );
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromAboveAllowanceReverts(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);
        assertTrue(token.approve(spender, allowance));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), allowance);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_DelegatedRoundTripPreservesSupply(uint256 amount, uint256 returnedAmount) public {
        amount = bound(amount, 0, SUPPLY);
        returnedAmount = bound(returnedAmount, 0, amount);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.approve(spender, returnedAmount));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(this), returnedAmount));
        assertEq(token.balanceOf(alice), amount - returnedAmount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount + returnedAmount);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
