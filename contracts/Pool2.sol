/* Copyright (C) 2017 NexusMutual.io

  This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

  This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
    along with this program.  If not, see http://www.gnu.org/licenses/ */

pragma solidity 0.4.24;

import "./MCR.sol";
import "./Pool1.sol";
import "./Quotation.sol";
import "./ClaimsReward.sol";
import "./PoolData.sol";
import "./Iupgradable.sol";
import "./imports/uniswap/solidity-interface.sol";
import "./imports/openzeppelin-solidity/math/SafeMath.sol";
import "./imports/openzeppelin-solidity/token/ERC20/ERC20.sol";


contract Pool2 is Iupgradable {
    using SafeMath for uint;

    MCR internal m1;
    Pool1 internal p1;
    PoolData internal pd;
    Quotation internal q2;
    Factory internal factory;
    address public uniswapFactoryAddress;
    uint internal constant DECIMAL1E18 = uint(10) ** 18;

    event Liquidity(bytes16 typeOf, bytes16 functionName);

    event Rebalancing(bytes4 iaCurr, uint tokenAmount);

    modifier checkPause {
        require(ms.isPause() == false);
        _;
    }

    modifier isMember {
        require(ms.isMember(msg.sender));
        _;
    }

    function () public payable {} 

    function changeUniswapFactoryAddress(address newFactoryAddress) external {
        require(ms.isOwner(msg.sender) || ms.checkIsAuthToGoverned(msg.sender));
        uniswapFactoryAddress = newFactoryAddress;
        factory = Factory(uniswapFactoryAddress);
    }

    /**
     * @dev On upgrade transfer all investment assets and ether to new Investment Pool
     * @param newPoolAddress New Investment Assest Pool address
     */
    function upgradeInvestmentPool(address newPoolAddress) external onlyInternal {
        for (uint64 i = 1; i < pd.getAllCurrenciesLen(); i++) {
            bytes4 iaName = pd.getCurrenciesByIndex(i);
            _upgradeInvestmentPool(iaName, newPoolAddress);
        }

        if (address(this).balance > 0)
            newPoolAddress.transfer(address(this).balance);
    }

    /**
     * @dev Handles the Callback of the Oraclize Query.
     * @param myid Oraclize Query ID identifying the query for which the result is being received
     */ 
    function delegateCallBack(bytes32 myid) external onlyInternal {
        
        bytes4 res = pd.getApiIdTypeOf(myid);

        if (ms.isPause() == false) { // system is not in emergency pause
            uint id = pd.getIdOfApiId(myid);
            if (res == "COV") {
                q2.expireCover(id);                
            } else if (res == "CLA") {
                ClaimsReward cr = ClaimsReward(ms.getLatestAddress("CR"));
                cr.changeClaimStatus(id);                
            } else if (res == "MCRF") {
                m1.addLastMCRData(uint64(id));                
            } else if (res == "ULT") {
                _externalLiquidityTrade();                
            }
        } else if (res == "EP") {
            bytes4 by;
            (, , by) = ms.getLastEmergencyPause();
            if (by == "AB") {
                ms.addEmergencyPause(false, "AUT"); //set pause to false                
            }
        }

        if (res != "") 
            pd.updateDateUpdOfAPI(myid);
    }

    /**
     * @dev Internal Swap of assets between Capital 
     * and Investment Sub pool for excess or insufficient  
     * liquidity conditions of a given currency.
     */ 
    function internalLiquiditySwap(bytes4 curr) external onlyInternal {
        uint caBalance;
        uint baseMin;
        uint varMin;
        (, baseMin, varMin) = pd.getCurrencyAssetVarBase(curr);
        caBalance = _getCurrencyAssetsBalance(curr);

        if (caBalance > uint(baseMin).add(varMin).mul(2)) {
            _internalExcessLiquiditySwap(curr, baseMin, varMin, caBalance);
        } else if (caBalance < uint(baseMin).add(varMin)) {
            _internalInsufficientLiquiditySwap(curr, baseMin, varMin, caBalance);
        }
    }

    /**
     * @dev Saves a given investment asset details. To be called daily.
     * @param curr array of Investment asset name.
     * @param rate array of investment asset exchange rate.
     * @param date current date in yyyymmdd.
     */ 
    function saveIADetails(bytes4[] curr, uint64[] rate, uint64 date) external checkPause {
        bytes4 maxCurr;
        bytes4 minCurr;
        uint64 maxRate;
        uint64 minRate;
        //ONLY NOTARZIE ADDRESS CAN POST
        require(pd.isnotarise(msg.sender));
        (maxCurr, maxRate, minCurr, minRate) = _calculateIARank(curr, rate);
        pd.saveIARankDetails(maxCurr, maxRate, minCurr, minRate, date);
        pd.updatelastDate(date);
        _rebalancingLiquidityTrading(maxCurr, maxRate);
        p1.saveIADetailsOracalise(pd.iaRatesTime());
    }

    /**
     * @dev Gets currency asset details for a given currency name.
     * @return caBalance currency asset balance
     * @return caRateX100 currency asset balance*100.
     * @return baseMin minimum base amount required in Capital Pool.
     * @return varMin  minimum variable amount required in Capital Pool.
     */ 
    function getCurrencyAssetDetails(
        bytes4 curr
    )
        external
        view
        returns(
            uint caBalance,
            uint caRateX100,
            uint baseMin,
            uint varMin
        )
    {
        caBalance = _getCurrencyAssetsBalance(curr);
        (, baseMin, varMin) = pd.getCurrencyAssetVarBase(curr);
        caRateX100 = pd.getCAAvgRate(curr);
    }

    function changeDependentContractAddress() public onlyInternal {
        m1 = MCR(ms.getLatestAddress("MC"));
        pd = PoolData(ms.getLatestAddress("PD"));
        p1 = Pool1(ms.getLatestAddress("P1"));
        q2 = Quotation(ms.getLatestAddress("QT")); 
    }

    function _rebalancingLiquidityTrading(
        bytes4 iaCurr,
        uint64 iaRate
    ) 
        internal
        checkPause
    {
        uint amountToSell;
        uint totalRiskBal = pd.getLastVfull();
        uint intermediaryEth;
        totalRiskBal = (totalRiskBal.mul(100000)).div(DECIMAL1E18);
        Exchange exchange;
        if (totalRiskBal > 0) {
            amountToSell = ((totalRiskBal.mul(2).mul(
                iaRate)).mul(pd.variationPercX100())).div(100 * 100 * 100000);
            amountToSell = (amountToSell.mul(
                10**uint(pd.getInvestmentAssetDecimals(iaCurr)))).div(100); // amount of asset to sell

            if (iaCurr != "ETH" && checkTradeConditions(iaCurr, iaRate, totalRiskBal)) {    
                exchange = Exchange(factory.getExchange(pd.getInvestmentAssetAddress(iaCurr)));
                intermediaryEth = exchange.getTokenToEthInputPrice(amountToSell);
                if (intermediaryEth > (address(exchange).balance.mul(4)).div(100)) { 
                    intermediaryEth = (address(exchange).balance.mul(4)).div(100);
                    amountToSell = (exchange.getEthToTokenInputPrice(intermediaryEth).mul(995)).div(1000);
                }
                
                exchange.tokenToEthSwapInput(amountToSell, (exchange.getTokenToEthInputPrice(
                    amountToSell).mul(995)).div(1000), pd.uniswapDeadline().add(now));
            } else if (iaCurr == "ETH" && checkTradeConditions(iaCurr, iaRate, totalRiskBal)) {
                _transferInvestmentAsset(iaCurr, address(p1), amountToSell);
            }
            emit Rebalancing(iaCurr, amountToSell); 
        }
    }

    /**
     * @dev Checks whether trading is required for a  
     * given investment asset at a given exchange rate.
     */ 
    function checkTradeConditions(
        bytes4 curr,
        uint64 iaRate,
        uint totalRiskBal
    )
        internal
        view
        returns(bool check)
    {
        if (iaRate > 0) {
            uint iaBalance =  _getInvestmentAssetBalance(curr).div(DECIMAL1E18);
            if (iaBalance > 0 && totalRiskBal > 0) {
                uint iaMax;
                uint iaMin;
                uint checkNumber;
                uint z;
                (iaMin, iaMax) = pd.getInvestmentAssetHoldingPerc(curr);
                z = pd.variationPercX100();
                checkNumber = (iaBalance.mul(100 * 100000)).div(totalRiskBal.mul(iaRate));
                if ((checkNumber > ((totalRiskBal.mul(iaMax.add(z))).div(100)).mul(100000)) ||
                    (checkNumber < ((totalRiskBal.mul(iaMin.sub(z))).div(100)).mul(100000)))
                    check = true; //eligibleIA
            }
        }
    }    
    
    /** 
     * @dev Gets the investment asset rank.
     */ 
    function getIARank(
        bytes4 curr,
        uint64 rateX100,
        uint totalRiskPoolBalance
    ) 
        internal
        view
        returns (int rhsh, int rhsl) //internal function
    {
        uint currentIAmaxHolding;
        uint currentIAminHolding;
        uint iaBalance = _getInvestmentAssetBalance(curr);
        (currentIAminHolding, currentIAmaxHolding) = pd.getInvestmentAssetHoldingPerc(curr);
        
        if (rateX100 > 0) {
            uint rhsf;
            rhsf = (iaBalance.mul(1000000)).div(totalRiskPoolBalance.mul(rateX100));
            rhsh = int(rhsf - currentIAmaxHolding);
            rhsl = int(rhsf - currentIAminHolding);
        }
    }

    /** 
     * @dev Calculates the investment asset rank.
     */  
    function _calculateIARank(
        bytes4[] curr,
        uint64[] rate
    )
        internal
        view
        returns(
            bytes4 maxCurr,
            uint64 maxRate,
            bytes4 minCurr,
            uint64 minRate
        )  
    {
        uint currentIAmaxHolding;
        uint currentIAminHolding;
        int max = 0;
        int min = -1;
        int rhsh;
        int rhsl;
        uint totalRiskPoolBalance;
        (totalRiskPoolBalance, ) = _totalRiskPoolBalance(curr, rate);
        for (uint i = 0; i < curr.length; i++) {
            rhsl = 0;
            rhsh = 0;
            if (pd.getInvestmentAssetStatus(curr[i])) {
                (currentIAminHolding, currentIAmaxHolding) = pd.getInvestmentAssetHoldingPerc(curr[i]);
                (rhsh, rhsl) = getIARank(curr[i], rate[i], totalRiskPoolBalance);
                if (rhsh > max) {
                    max = rhsh;
                    maxCurr = curr[i];
                    maxRate = rate[i];
                } else if (rhsl < min || rhsl == 0 || min == -1) {
                    min = rhsl;
                    minCurr = curr[i];
                    minRate = rate[i];
                }
            }
        }
    }

    /**
     * @dev Gets the equivalent investment asset Pool2 balance in ether.
     * @param iaCurr array of Investment asset name.
     * @param iaRate array of investment asset exchange rate. 
     */ 
    function _totalRiskPoolBalance(
        bytes4[] iaCurr,
        uint64[] iaRate
    ) 
        internal
        view
        returns(uint balance, uint iaBalance)
    {
        uint capitalPoolBalance;
        (capitalPoolBalance, ) = m1.calVtpAndMCRtp();
        for (uint i = 0; i < iaCurr.length; i++) {
            if (iaRate[i] > 0) {
                iaBalance = (iaBalance.add(_getInvestmentAssetBalance(
                iaCurr[i])).mul(100)).div(iaRate[i]);
            }
        }
        balance = capitalPoolBalance.add(iaBalance);
    }

    /** 
     * @dev Gets currency asset balance for a given currency name.
     */   
    function _getCurrencyAssetsBalance(bytes4 _curr) internal view returns(uint caBalance) {
        if (_curr == "ETH") {
            caBalance = address(p1).balance;
        } else {
            ERC20 erc20 = ERC20(pd.getCurrencyAssetAddress(_curr));
            caBalance = erc20.balanceOf(address(p1));
        }
    }

    function _getInvestmentAssetBalance(bytes4 _curr) internal view returns (uint balance) {
        if (_curr == "ETH") {
            balance = address(this).balance;
        } else {
            ERC20 erc20 = ERC20(pd.getInvestmentAssetAddress(_curr));
            balance = erc20.balanceOf(address(this));
        }
    }

    /**
     * @dev Creates Excess liquidity trading order for a given currency and a given balance.
     */  
    function _internalExcessLiquiditySwap(bytes4 _curr, uint _baseMin, uint _varMin, uint _caBalance) internal {
        // require(ms.isInternal(msg.sender) || md.isnotarise(msg.sender));
        bytes4 minIACurr;
        uint amount;
        
        (, , minIACurr, ) = pd.getIARankDetailsByDate(pd.getLastDate());
        if (_curr == minIACurr) {
            amount = _caBalance.sub(((_baseMin.add(_varMin)).mul(3)).div(2)); //*10**18;
            p1.transferCurrencyAsset(_curr, address(this), amount);
        } else {
            p1.triggerExternalLiquidityTrade();
        }
    }

    /** 
     * @dev insufficient liquidity swap  
     * for a given currency and a given balance.
     */ 
    function _internalInsufficientLiquiditySwap(bytes4 _curr, uint _baseMin, uint _varMin, uint _caBalance) internal {
        
        bytes4 maxIACurr;
        uint amount;
        
        (maxIACurr, , , ) = pd.getIARankDetailsByDate(pd.getLastDate());
        
        if (_curr == maxIACurr) {
            amount = (((_baseMin.add(_varMin)).mul(3)).div(2)).sub(_caBalance);
            _transferInvestmentAsset(_curr, ms.getLatestAddress("P1"), amount);
        } else {
            p1.triggerExternalLiquidityTrade();
        }
    }

    /**
     * @dev Creates External excess liquidity trading  
     * order for a given currency and a given balance.
     * @param curr Currency Asset to Sell
     * @param minIACurr Investment Asset to Buy  
     * @param amount Amount of Currency Asset to Sell
     */  
    function externalExcessLiquiditySwap(
        bytes4 curr,
        bytes4 minIACurr,
        uint256 amount
    )
        internal
        returns (bool trigger)
    {
        uint intermediaryEth;
        Exchange exchange;
        ERC20 erc20;
    
        if (curr == minIACurr) {
            p1.transferCurrencyAsset(curr, address(this), amount);
        } else if (curr == "ETH" && minIACurr != "ETH") {
            p1.transferCurrencyAsset(curr, address(this), amount);
            exchange = Exchange(factory.getExchange(pd.getInvestmentAssetAddress(minIACurr)));
            if (amount > (address(exchange).balance.mul(4)).div(100)) { // 4% ETH volume limit 
                amount = (address(exchange).balance.mul(4)).div(100);
                trigger = true;
            }
            exchange.ethToTokenSwapInput.value((exchange.getTokenToEthInputPrice(
            amount).mul(995)).div(1000))(amount, pd.uniswapDeadline().add(now));    
        } else if (curr != "ETH" && minIACurr == "ETH") {
            p1.transferCurrencyAsset(curr, address(this), amount);
            exchange = Exchange(factory.getExchange(pd.getCurrencyAssetAddress(curr)));
            erc20 = ERC20(pd.getCurrencyAssetAddress(curr));
            intermediaryEth = exchange.getTokenToEthInputPrice(amount);

            if (intermediaryEth > (address(exchange).balance.mul(4)).div(100)) { 
                intermediaryEth = (address(exchange).balance.mul(4)).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;
            }

            erc20.decreaseAllowance(address(exchange), erc20.allowance(address(this), address(exchange)));
            erc20.approve(address(exchange), amount);
            exchange.tokenToEthSwapInput(amount, (
                intermediaryEth.mul(995)).div(1000), pd.uniswapDeadline().add(now));   
        } else {
            p1.transferCurrencyAsset(curr, address(this), amount);
            exchange = Exchange(factory.getExchange(pd.getCurrencyAssetAddress(curr)));
            intermediaryEth = exchange.getTokenToEthInputPrice(amount);

            if (intermediaryEth > (address(exchange).balance.mul(4)).div(100)) { 
                intermediaryEth = (address(exchange).balance.mul(4)).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;
            }
            
            Exchange tmp = Exchange(factory.getExchange(
                pd.getInvestmentAssetAddress(minIACurr))); // minIACurr exchange

            if (intermediaryEth > address(tmp).balance.mul(4).div(100)) { 
                intermediaryEth = address(tmp).balance.mul(4).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;   
            }

            erc20 = ERC20(pd.getCurrencyAssetAddress(curr));
            erc20.decreaseAllowance(address(exchange), erc20.allowance(address(this), address(exchange)));
            erc20.approve(address(exchange), amount);
            exchange.tokenToTokenSwapInput(amount, (tmp.getEthToTokenInputPrice(
                intermediaryEth).mul(995)).div(1000), (intermediaryEth.mul(995)).div(1000), 
                    pd.uniswapDeadline().add(now), pd.getInvestmentAssetAddress(minIACurr));
        }
    }

    /** 
     * @dev insufficient liquidity swap  
     * for a given currency and a given balance.
     * @param curr Currency Asset to buy
     * @param maxIACurr Investment Asset to sell
     * @param amount Amount of Investment Asset to sell
     */ 
    function externalInsufficientLiquiditySwap(
        bytes4 curr,
        bytes4 maxIACurr,
        uint256 amount
    ) 
        internal
        returns (bool trigger)
    {   

        Exchange exchange;
        ERC20 erc20;
        uint intermediaryEth;

        if (curr == maxIACurr) {
            _transferInvestmentAsset(curr, address(p1), amount);
        } else if (curr == "ETH" && maxIACurr != "ETH") {
            exchange = Exchange(factory.getExchange(pd.getInvestmentAssetAddress(maxIACurr)));
            intermediaryEth = exchange.getTokenToEthInputPrice(amount);

            if (intermediaryEth > (address(exchange).balance.mul(4)).div(100)) { 
                intermediaryEth = (address(exchange).balance.mul(4)).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;
            }

            erc20 = ERC20(pd.getCurrencyAssetAddress(maxIACurr));
            erc20.decreaseAllowance(address(exchange), erc20.allowance(address(this), address(exchange)));
            erc20.approve(address(exchange), amount);
            exchange.tokenToEthTransferInput(amount, (
                intermediaryEth.mul(995)).div(1000), pd.uniswapDeadline().add(now), address(p1)); 

        } else if (curr != "ETH" && maxIACurr == "ETH") {
            exchange = Exchange(factory.getExchange(pd.getCurrencyAssetAddress(curr)));
            if (amount > (address(exchange).balance.mul(4)).div(100)) { // 4% ETH volume limit 
                amount = (address(exchange).balance.mul(4)).div(100);
                trigger = true;
            }
            exchange.ethToTokenTransferInput.value(amount)((exchange.getEthToTokenInputPrice(
                amount).mul(995)).div(1000), pd.uniswapDeadline().add(now), address(p1));   
        } else {
            exchange = Exchange(factory.getExchange(pd.getCurrencyAssetAddress(maxIACurr)));
            intermediaryEth = exchange.getTokenToEthInputPrice(amount);
            if (intermediaryEth > (address(exchange).balance.mul(4)).div(100)) { 
                intermediaryEth = (address(exchange).balance.mul(4)).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;
            }
            address iaAddress = pd.getInvestmentAssetAddress(curr);
            Exchange tmp = Exchange(factory.getExchange(iaAddress));

            if (intermediaryEth > address(tmp).balance.mul(4).div(100)) { 
                intermediaryEth = address(tmp).balance.mul(4).div(100);
                amount = exchange.getEthToTokenInputPrice(intermediaryEth);
                trigger = true;
            }
            erc20 = ERC20(pd.getCurrencyAssetAddress(maxIACurr));
            erc20.decreaseAllowance(address(exchange), erc20.allowance(address(this), address(exchange)));
            erc20.approve(address(exchange), amount);
            exchange.tokenToTokenTransferInput(amount, (
                tmp.getEthToTokenInputPrice(intermediaryEth).mul(995)).div(1000), (
                    intermediaryEth.mul(995)).div(1000), pd.uniswapDeadline().add(now), address(p1), iaAddress);
        }
    }

    /**
     * @dev External Trade for excess or insufficient  
     * liquidity conditions of a given currency.
     */ 
    function _externalLiquidityTrade() internal {
        
        bool triggerTrade;
        bytes4 curr;
        bytes4 minIACurr;
        bytes4 maxIACurr;
        uint amount;
        uint minIARate;
        uint maxIARate;
        uint baseMin;
        uint varMin;
        uint caBalance;

        (maxIACurr, maxIARate, minIACurr, minIARate) = pd.getIARankDetailsByDate(pd.getLastDate());
        for (uint64 i = 0; i < pd.getAllCurrenciesLen(); i++) {
            curr = pd.getCurrenciesByIndex(i);
            (, baseMin, varMin) = pd.getCurrencyAssetVarBase(curr);
            caBalance = _getCurrencyAssetsBalance(curr).div(DECIMAL1E18);

            if (caBalance > uint(baseMin).add(varMin).mul(2)) { //excess
                amount = caBalance.sub(((uint(baseMin).add(varMin)).mul(3)).div(2)); //*10**18;
                triggerTrade = externalExcessLiquiditySwap(curr, minIACurr, amount);
            } else if (caBalance < uint(baseMin).add(varMin)) { // insufficient
                amount = (((uint(baseMin).add(varMin)).mul(3)).div(2)).sub(caBalance);
                triggerTrade = externalInsufficientLiquiditySwap(curr, maxIACurr, amount);
            }

            if (triggerTrade) {
                p1.triggerExternalLiquidityTrade();
            }
        }
    }

    /** 
     * @dev Transfers ERC20 investment asset from this Pool to another Pool.
     */ 
    function _transferInvestmentAsset(
        bytes4 _curr,
        address _transferTo,
        uint _amount
    ) 
        internal
    {
        if (_curr == "ETH") {
            _transferTo.transfer(_amount);
        } else {
            ERC20 erc20 = ERC20(pd.getInvestmentAssetAddress(_curr));
            erc20.transfer(_transferTo, _amount);
        }
    }

    /** 
     * @dev Transfers ERC20 investment asset from this Pool to another Pool.
     */ 
    function _upgradeInvestmentPool(
        bytes4 _curr,
        address _newPoolAddress
    ) 
        internal
    {
        ERC20 erc20 = ERC20(pd.getInvestmentAssetAddress(_curr));
        if (erc20.balanceOf(address(this)) > 0)
            erc20.transfer(_newPoolAddress, erc20.balanceOf(address(this)));
    }
}