// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "src/TestToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Closed actor set: every transfer stays in the model, including self-transfers.
contract TokenSequenceHandler is Test {
    TestToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(TestToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000 ether;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 rawAmount, bool unlimited) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = unlimited ? type(uint256).max : bound(rawAmount, 0, token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 fromSeed, uint8 toSeed, uint8 spenderSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 authorized = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from];
        uint256 amount = bound(rawAmount, 0, available < authorized ? available : authorized);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (authorized != type(uint256).max) expectedAllowance[from][spender] -= amount;
    }

    function overdraw(uint8 fromSeed, uint8 toSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 balance = expectedBalance[from];
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        token.transfer(to, balance + 1);
    }

    // An allowance decrement before a balance failure must roll back too.
    function approvedOverdraw(uint8 fromSeed, uint8 toSeed, uint8 spenderSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 balance = expectedBalance[from];
        vm.prank(from);
        assertTrue(token.approve(spender, balance + 1));
        expectedAllowance[from][spender] = balance + 1;
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        token.transferFrom(from, to, balance + 1);
    }

    function invalidRecipient(uint8 fromSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % 4];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenStatefulTest is Test {
    TestToken internal token;
    TokenSequenceHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        token = new TestToken();
        actors = [makeAddr("factory"), makeAddr("swarm"), makeAddr("pool"), makeAddr("holder")];
        handler = new TokenSequenceHandler(token, actors);
        assertTrue(token.transfer(actors[0], token.totalSupply()));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = TokenSequenceHandler.transfer.selector;
        selectors[1] = TokenSequenceHandler.approve.selector;
        selectors[2] = TokenSequenceHandler.transferFrom.selector;
        selectors[3] = TokenSequenceHandler.overdraw.selector;
        selectors[4] = TokenSequenceHandler.approvedOverdraw.selector;
        selectors[5] = TokenSequenceHandler.invalidRecipient.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Fixed supply and exact transfers are explicit launch requirements.
    function invariant_supplyAndEveryHolderMatchTheTransferLedger() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]));
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_onlyAuthorizedAmountsCanBeSpent() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
    }
}
