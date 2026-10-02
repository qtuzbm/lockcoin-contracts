require("@nomicfoundation/hardhat-toolbox");

// Same compiler settings as the deployed, source-verified contracts:
// solc 0.8.28 · optimizer on, 200 runs · evmVersion paris.
module.exports = {
  solidity: { version: "0.8.28", settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "paris" } },
};
