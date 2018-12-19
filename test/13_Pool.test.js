const Pool1 = artifacts.require('Pool1');
const Pool2 = artifacts.require('Pool2');
const PoolData = artifacts.require('PoolData');

const { advanceBlock } = require('./utils/advanceToBlock');
const { ether } = require('./utils/ether');
const { increaseTimeTo, duration } = require('./utils/increaseTime');
const { latestTime } = require('./utils/latestTime');

let p1;
let p2;
let pd;

const BigNumber = web3.BigNumber;
const newAsset = '0x535253';
const CA_DAI = '0x4441490000000000';
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const NEW_ADDRESS = '0xb24919181daead6635e613576ca11c5aa5a4e133';

require('chai')
  .use(require('chai-bignumber')(BigNumber))
  .should();

contract('Pool', function([owner, notOwner]) {
  before(async function() {
    await advanceBlock();
    p1 = await Pool1.deployed();
    p2 = await Pool2.deployed();
    pd = await PoolData.deployed();
  });

  describe('PoolData', function() {
    it('should return correct data', async function() {
      await pd.getAllCurrencies();
      const caIndex = await pd.getAllCurrenciesLen();
      (await pd.getAllCurrenciesByIndex(caIndex - 1)).should.equal(CA_DAI);
      await pd.getAllInvestmentCurrencies();
      const iaIndex = await pd.getInvestmentCurrencyLen();
      (await pd.getInvestmentCurrencyByIndex(iaIndex - 1)).should.equal(CA_DAI);
    });
    it('should be able to add new Currency Asset', async function() {
      await pd.addCurrencyAssetCurrency(newAsset, ZERO_ADDRESS, 1);
      await pd.getCurrencyAssetVarBase(newAsset);
      (await pd.getCurrencyAssetAddress(newAsset)).should.equal(ZERO_ADDRESS);
      (await pd.getCurrencyAssetVarMin(newAsset)).should.be.bignumber.equal(0);
      (await pd.getCurrencyAssetBaseMin(newAsset)).should.be.bignumber.equal(1);
    });
    it('should be able to add new Investment Asset', async function() {
      await pd.addInvestmentAssetCurrency(
        newAsset,
        ZERO_ADDRESS,
        false,
        4000,
        8500,
        18
      );
      await pd.getInvestmentAssetDetails(newAsset);
      (await pd.getInvestmentAssetStatus(newAsset)).should.equal(false);
      (await pd.getInvestmentAssetAddress(newAsset)).should.equal(ZERO_ADDRESS);
      (await pd.getInvestmentAssetMinHoldingPerc(
        newAsset
      )).should.be.bignumber.equal(4000);
      (await pd.getInvestmentAssetMaxHoldingPerc(
        newAsset
      )).should.be.bignumber.equal(8500);
      (await pd.getInvestmentAssetDecimals(newAsset)).should.be.bignumber.equal(
        18
      );
    });
    it('should be able to change Variation Percentage', async function() {
      await pd.changeVariationPercX100(400);
      (await pd.variationPercX100()).should.be.bignumber.equal(400);
    });
    it('should be able to change Uniswap Deadline time', async function() {
      await pd.changeUniswapDeadlineTime(duration.minutes(26));
      (await pd.uniswapDeadline()).should.be.bignumber.equal(
        duration.minutes(26)
      );
    });
    it('should be able to change liquidity Trade Callback Time', async function() {
      await pd.changeliquidityTradeCallbackTime(duration.hours(5));
      (await pd.liquidityTradeCallbackTime()).should.be.bignumber.equal(
        duration.hours(5)
      );
    });
    it('should be able to change Investment Asset rate time', async function() {
      await pd.changeIARatesTime(duration.hours(26));
      (await pd.iaRatesTime()).should.be.bignumber.equal(duration.hours(26));
    });
    it('should be able to set last Liquidity Trade Trigger', async function() {
      await pd.changeIARatesTime(duration.hours(26));
      (await pd.iaRatesTime()).should.be.bignumber.equal(duration.hours(26));
    });
    it('should be able to change Currency Asset address', async function() {
      await pd.changeCurrencyAssetAddress(newAsset, NEW_ADDRESS);
      (await pd.getCurrencyAssetAddress(newAsset)).should.equal(NEW_ADDRESS);
    });
    it('should be able to change Currency Asset Base Minimum', async function() {
      await pd.changeCurrencyAssetBaseMin(newAsset, 2);
      (await pd.getCurrencyAssetBaseMin(newAsset)).should.be.bignumber.equal(2);
    });
    it('should be able to change Currency Asset Var Minimum', async function() {
      await pd.changeCurrencyAssetVarMin(newAsset, 1);
      (await pd.getCurrencyAssetVarMin(newAsset)).should.be.bignumber.equal(1);
    });
    it('should be able to change Investment Asset address', async function() {
      await pd.changeInvestmentAssetAddress(newAsset, NEW_ADDRESS);
      (await pd.getInvestmentAssetAddress(newAsset)).should.equal(NEW_ADDRESS);
    });
    it('should be able to update Investment Asset Decimals', async function() {
      await pd.updateInvestmentAssetDecimals(newAsset, 19);
      (await pd.getInvestmentAssetDecimals(newAsset)).should.be.bignumber.equal(
        19
      );
    });
    it('should be able to change Investment Asset Status', async function() {
      await pd.changeInvestmentAssetStatus(newAsset, true);
      (await pd.getInvestmentAssetStatus(newAsset)).should.equal(true);
    });
    it('should be able to change Investment Asset Holding Percentage', async function() {
      await pd.changeInvestmentAssetHoldingPerc(newAsset, 4500, 9000);
      (await pd.getInvestmentAssetMinHoldingPerc(
        newAsset
      )).should.be.bignumber.equal(4500);
      (await pd.getInvestmentAssetMaxHoldingPerc(
        newAsset
      )).should.be.bignumber.equal(9000);
    });
    it('should return Investment Asset Rank Details', async function() {
      const lastDate = await pd.getLastDate();
      await pd.getIARankDetailsByDate(lastDate);
    });
    it('should return data', async function() {
      const length = await pd.getApilCallLength();
      const myId = await pd.getApiCallIndex(length - 1);
      await pd.getApiCallDetails(myId);
      await pd.getDateUpdOfAPI(myId);
      await pd.getCurrOfApiId(myId);
      await pd.getDateUpdOfAPI(myId);
      await pd.getDateAddOfAPI(myId);
      await pd.getApiIdTypeOf(myId);
    });
  });

  // describe('', function() {
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  // });

  // describe('', function() {
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  // });

  // describe('', function() {
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  //   it('should be able to', async function() {

  //   });
  // });
});
