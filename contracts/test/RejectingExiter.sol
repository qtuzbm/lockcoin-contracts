// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVaultX {
    function buy() external payable;
    function exit() external;
    function claim() external;
}

/// 测试网正向验收「打款失败 → 记入 pending → 之后 claim」用的持仓合约。
/// RejectingBuyer 只能 buy/claim、不能 exit，只能等十倍自动卖出才触发 pending；
/// 在已有十几个在场仓位的公开测试网上新仓位排在队尾，等不到。这个合约能自己 exit。
/// 只有部署者能操作，免得公开测试网上有人拿它捣乱；sweep 把领回的测试币还给部署者。
contract RejectingExiter {
    address public immutable owner;
    bool public accept;

    constructor() { owner = msg.sender; }
    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }

    function setAccept(bool a) external onlyOwner { accept = a; }
    function doBuy(address v) external payable onlyOwner { IVaultX(v).buy{value: msg.value}(); }
    function doExit(address v) external onlyOwner { IVaultX(v).exit(); }
    function doClaim(address v) external onlyOwner { IVaultX(v).claim(); }
    function sweep() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        require(ok, "sweep");
    }
    receive() external payable { require(accept, "nope"); }
}
