// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LockCoin — 锁仓币
/// @notice 余额在持有人钱包里可见，但持有人之间**任何转账一律拒绝**（锁仓）。
///         只有金库(vault)能铸造/销毁：买入时铸给买家，自动卖出/到期退出时从买家销毁。
///         没有 owner、没有税、没有黑白名单、没有暂停开关。
contract LockCoin is ERC20 {
    address public immutable vault;

    error Locked();
    error OnlyVault();

    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) {
        vault = vault_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        _burn(from, amount);
    }

    /// @dev 只放行 铸造(from==0) 与 销毁(to==0)；持有人之间转账全部 revert。
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert Locked();
        super._update(from, to, value);
    }
}
