const SmartSwap = artifacts.require("SmartSwap");

module.exports = async function (deployer) {
    if (deployer.network.indexOf('skipMigrations') > -1) { // skip migration
        return;
    }
    if (deployer.network.indexOf('kovan_oracle') > -1) { // skip migration
        return;
    }
    if (deployer.network_id == 4) { // Rinkeby
        // let compoundOracleAddress = "0x332b6e69f21acdba5fb3e8dac56ff81878527e06";
        // let stringComparatorLibrary = await deployer.deploy(stringComparator);
        // let oracleContract = await deployer.deploy(ploutozOracle, compoundOracleAddress);
        // let wethContract = await deployer.deploy(weth);
        // console.log('WETH contract address: ' + wethContract.address);
        // let exchangeContract = await deployer.deploy(exchange, uniswapFactoryAddress, uniswapRouter01Address, uniswapRouter02Address, address0);
        // deployer.link(stringComparator, factory);
        // let factoryContract = await deployer.deploy(factory, oracleContract.address, exchangeContract.address);
        // let exchangeContract=await deployer.
    } else if (deployer.network_id == 1) { // main net
    } else if (deployer.network_id == 5777) {
    } else if (deployer.network_id == 42) { // kovan
    } else if (deployer.network_id == 56) { // bsc main net

    } else if (deployer.network_id == 97) { //bsc test net
        await deployer.deploy(SmartSwap);
    } else {

    }

    // deployer.deploy(factory).then(() => {
    // });
    // deployer.deploy(exchange).then(() => {
    // });
};
