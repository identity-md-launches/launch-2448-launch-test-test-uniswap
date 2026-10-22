// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only IMD stand-in with transfer failure and reentrancy injection.
contract MockIMD is ERC20 {
    address public rejectedRecipient;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function reject(address recipient) external {
        rejectedRecipient = recipient;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == rejectedRecipient) return false;
        if (reentryTarget != address(0)) {
            address target = reentryTarget;
            reentryTarget = address(0);
            (reentrySucceeded, reentryResult) = target.call(reentryData);
        }
        return super.transfer(to, amount);
    }
}
