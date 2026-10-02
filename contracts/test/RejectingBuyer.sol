// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVault { function buy() external payable; function claim() external; }

/// 拒收原生币的买家合约：用来测试「自动打款失败 → 记入 pending → 之后 claim」这条路
contract RejectingBuyer {
    bool public accept;
    function setAccept(bool a) external { accept = a; }
    function doBuy(address v) external payable { IVault(v).buy{value: msg.value}(); }
    function doClaim(address v) external { IVault(v).claim(); }
    receive() external payable { require(accept, "nope"); }
}
