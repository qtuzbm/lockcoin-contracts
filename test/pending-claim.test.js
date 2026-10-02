const { expect } = require("chai");
const { ethers } = require("hardhat");

// 本地先跑通测试网要做的同一条路：拒收合约买票 → exit 打款失败 → pending/totalPending 记账 → 放行后 claim 领回
describe("SpiralVault v3.2 · 退出打款失败 → pending → claim（测试网验收的本地预演）", function () {
  it("exit 时收款方拒收：钱记进 pending 与 totalPending，账平；放行后 claim 全额到账", async () => {
    const TICKET = ethers.parseEther("0.0001");
    const pons = await (await ethers.getContractFactory("MockPonsCurve")).deploy();
    const V = await ethers.getContractFactory("SpiralVault");
    const vault = await V.deploy("LockCoin RH", "LOCKR", TICKET, 10n, TICKET * 2n, ethers.parseEther("1000000"), 0, 10, await pons.getAddress(), 1500n);
    const [dev, a, b] = await ethers.getSigners();
    await vault.connect(a).buy({ value: TICKET });          // 前面先有人在场，跟公开测试网一样
    await vault.connect(b).buy({ value: TICKET });

    const ex = await (await ethers.getContractFactory("RejectingExiter")).deploy();
    const exAddr = await ex.getAddress(), vAddr = await vault.getAddress();
    await ex.doBuy(vAddr, { value: TICKET });
    const quote = (await vault.infoOf(exAddr)).currentValue;
    expect(quote).to.be.gt(0n);

    await expect(ex.doExit(vAddr)).to.emit(vault, "PendingCredited").withArgs(exAddr, quote);
    expect(await vault.pending(exAddr)).to.equal(quote);
    expect(await vault.totalPending()).to.equal(quote);
    let [ok] = await vault.solvent(); expect(ok).to.equal(true);

    await expect(ex.doClaim(vAddr)).to.be.revertedWith("claim failed");   // 还没放行：领不走，钱也没丢
    expect(await vault.pending(exAddr)).to.equal(quote);

    await ex.setAccept(true);
    await expect(ex.doClaim(vAddr)).to.emit(vault, "Claimed").withArgs(exAddr, quote);
    expect(await vault.pending(exAddr)).to.equal(0n);
    expect(await vault.totalPending()).to.equal(0n);
    expect(await ethers.provider.getBalance(exAddr)).to.equal(quote);
    [ok] = await vault.solvent(); expect(ok).to.equal(true);

    const before = await ethers.provider.getBalance(dev.address);
    await ex.sweep();
    expect(await ethers.provider.getBalance(exAddr)).to.equal(0n);
    expect(await ethers.provider.getBalance(dev.address)).to.be.gt(before - ethers.parseEther("0.001"));
  });

  it("只有部署者能操作这个测试合约", async () => {
    const [, stranger] = await ethers.getSigners();
    const ex = await (await ethers.getContractFactory("RejectingExiter")).deploy();
    await expect(ex.connect(stranger).setAccept(true)).to.be.revertedWith("owner");
    await expect(ex.connect(stranger).sweep()).to.be.revertedWith("owner");
  });
});
