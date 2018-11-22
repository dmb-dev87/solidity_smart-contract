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

import "./NXMToken.sol";
import "./Pool1.sol";
import "./PoolData.sol";
import "./MCRData.sol";
import "./QuotationData.sol";
import "./Iupgradable.sol";
import "./imports/openzeppelin-solidity/math/SafeMath.sol";
import "./imports/openzeppelin-solidity/token/ERC20/ERC20.sol";


contract MCR is Iupgradable {
    using SafeMath for uint;

    Pool1 internal p1;
    PoolData internal pd;
    NXMToken internal tk;
    MCRData internal md;
    QuotationData internal qd;

    uint private constant DECIMAL1E18 = uint(10) ** 18;
    uint private constant DECIMAL1E08 = uint(10) ** 8;

    event MCREvent(
        uint indexed date,
        uint blockNumber,
        bytes4[] allCurr,
        uint32[] allCurrRates,
        uint mcrEtherx100,
        uint32 mcrPercx100,
        uint vFull
    );

    modifier onlyOwner {
        require(ms.isOwner(msg.sender) == true);
        _;
    }

    modifier checkPause {
        require(ms.isPause() == false);
        _;
    }

    /// @dev Changes minimum Capital Requirement for system to sustain.
    function changeMinReqMCR(uint32 minMCR) external onlyInternal {
        md.changeMinReqMCR(minMCR);
    }
    
    /// @dev Changes time period for obtaining new MCR data from external oracle query.
    function changeMCRTime(uint64 _time) external onlyOwner {

        md.changeMCRTime(_time);
    }

    /// @dev Stores name of currencies accepted by the system.
    /// @param curr Currency Name.
    function addCurrency(bytes4 curr) external checkPause {

        require(ms.isInternal(msg.sender) == true || ms.isOwner(msg.sender) == true);
        md.addCurrency(curr);
    }

    /// @dev Changes scaling factor which determines token price.
    function changeSF(uint32 val) external onlyOwner {
        md.changeSF(val);
    }

    /// @dev Changes address which can notise MCR
    function changenotariseAddress(address add) external onlyOwner {
        md.changeNotariseAdd(add);
    }

    /// @dev Adds new MCR data.
    /// @param mcrP  Minimum Capital Requirement in percentage.
    /// @param vF Pool1 fund value in Ether used in the last full daily calculation of the Capital model.
    /// @param onlyDate  Date(yyyymmdd) at which MCR details are getting added.
    function addMCRData(
        uint32 mcrP,
        uint32 mcrE,
        uint vF,
        bytes4[] curr,
        uint32[] _threeDayAvg,
        uint64 onlyDate
    )
        external
        checkPause
    {
        require(md.isnotarise(msg.sender));
        uint len = md.getMCRDataLength();
        addMCRDataExtended(len, onlyDate, curr, mcrE, mcrP, vF.mul(DECIMAL1E18), _threeDayAvg);
    }

    /// @dev Adds MCR Data for last failed attempt.
    function addLastMCRData(uint64 date) external checkPause {
        uint64 lastdate = md.getLastMCRDate();
        uint64 failedDate = uint64(date);
        if (failedDate >= lastdate) {
            uint32 mcrP;
            uint32 mcrE;
            uint vF;
            (mcrP, mcrE, vF, ) = md.getLastMCR();
            uint16 len = md.getCurrLength();
            md.pushMCRData(mcrP, mcrE, vF, date);
            for (uint16 j = 0; j < len; j++) {
                bytes4 currName = md.getCurrencyByIndex(j);
                md.updateCurr3DaysAvg(currName, md.getCurr3DaysAvg(currName));
            }

            emit MCREvent(date, block.number, new bytes4[](0), new uint32[](0), mcrE, mcrP, vF);
            // Oraclize call for next MCR calculation
            callOracliseForMCR();
        }
    }

    /// @dev Checks if last notarised Minimum Capital Requirement(MCR) percentage < minimum capital required or not.
    /// @return check 1 if last added MCR% < Minimum MCR value
    function checkForMinMCR() external view returns(uint8 check) {

        check = 0;
        if (md.getLastMCRPerc() < md.getMinMCR())
            check = 1;
    }

    /// @dev Gets name of currency at a given index.
    function getCurrencyByIndex(uint16 index) external view returns(uint16 id, bytes4 curr) {
        curr = md.getCurrencyByIndex(index);
        id = index;
    }

    function changeDependentContractAddress() public onlyInternal {
        md = MCRData(ms.getLatestAddress("MD"));
        qd = QuotationData(ms.getLatestAddress("QD"));
        p1 = Pool1(ms.getLatestAddress("P1"));
        pd = PoolData(ms.getLatestAddress("PD"));
        tk = NXMToken(ms.tokenAddress());
    }

    /// @dev Gets total sum assured(in ETH).
    function getAllSumAssurance() public view returns(uint amount) {
        uint len = md.getCurrLength();
        for (uint16 i = 0; i < len; i++) {
            bytes4 currName = md.getCurrencyByIndex(i);
            if (currName == "ETH") {
                amount = amount.add(qd.getTotalSumAssured(currName));
            } else {
                if (md.getCurr3DaysAvg(currName) > 0)
                    amount = amount.add((qd.getTotalSumAssured(currName).mul(100)).div(md.getCurr3DaysAvg(currName)));
            }
        }
    }

    /// @dev Calculates V(Tp) ,i.e, Pool Fund Value in Ether used for the Token Price Calculation
    //                      and MCR%(Tp),i.e, MCR% used in the Token Price Calculation.
    /// @return vtp  Pool Fund Value in Ether used for the Token Price Model
    /// @return mcrtp MCR% used in the Token Price Model.
    function calVtpAndMCRtp() public view returns(uint vtp, uint mcrtp) {
        vtp = 0;
        ERC20 erc20;
        for (uint i = 1; i < md.getCurrLength(); i++) {
            bytes4 currency = md.getCurrencyByIndex(uint16(i));
            erc20 = ERC20(pd.getCurrencyAssetAddress(currency));
            uint currTokens = erc20.balanceOf(ms.getLatestAddress("P1"));
            if (md.getCurr3DaysAvg(currency) > 0)
                vtp = vtp.add((currTokens.mul(100)).div(md.getCurr3DaysAvg(currency)));
        }
        vtp = vtp.add(p1.getEtherPoolBalance());
        uint mcrFullperc;
        uint vFull;
        (mcrFullperc, , vFull, ) = md.getLastMCR();
        if (vFull > 0) {
            mcrtp = (mcrFullperc.mul(vtp)).div(vFull);
        }
    }

   /**
    * @dev Calculates the Token Price of NXM in a given currency.
    * @param curr Currency name.
    * @param totalSupply Tokens in circulation
    */
    function calculateTokenPriceWithSupply(
        bytes4 curr,
        uint totalSupply
    ) 
        public
        view
        onlyInternal
        returns(uint tokenPrice)
    {
        return _calculateTokenPrice(curr, totalSupply);
    }

    /**
    * @dev Calculates the Token Price of NXM in a given currency with provided
    *       token supply for dynamic token price calculation
    * @param curr Currency name.
    */ 
    function calculateTokenPrice (bytes4 curr) public view returns(uint tokenPrice) {
        return _calculateTokenPrice(curr, tk.totalSupply());
    }
    
    /// @dev Gets max numbers of tokens that can be sold at the moment.
    function getMaxSellTokens() public view returns(uint maxTokens) {
        uint maxTokensAccPoolBal  = p1.getEtherPoolBalance().sub(((
            uint(pd.getCurrencyAssetBaseMin("ETH")).mul(50)).div(100)).mul(DECIMAL1E18));
        maxTokensAccPoolBal = (maxTokensAccPoolBal.div((calculateTokenPrice("ETH")
            .div(1000)).mul(975))).mul(DECIMAL1E18);
        maxTokens = (((uint(md.getLastMCRPerc()).sub(10000)).mul(2000)).div(10000)).mul(DECIMAL1E18); 
        if (maxTokens > maxTokensAccPoolBal)
            maxTokens = maxTokensAccPoolBal;     
    }

    /// @dev Calls oraclize query to calculate MCR details after 24 hours.
    function callOracliseForMCR() internal {
        p1.mcrOraclise(md.getMCRTime());
    }

    /// @dev Calculates the Token Price of NXM in a given currency with provided
    ///       token supply for dynamic token price calculation
    /// @param _curr Currency name.
    /// @param _totalSupply token supply
    /// @return tokenPrice Token price.
    function _calculateTokenPrice(bytes4 _curr, uint _totalSupply) internal view returns(uint tokenPrice) {
        uint mcrtp;
        (, mcrtp) = calVtpAndMCRtp();
        uint totalSupply = _totalSupply.div(DECIMAL1E18);
        uint getSFx100000;
        uint getGrowthStep;
        uint getCurr3DaysAvg;
        (getSFx100000, getGrowthStep, getCurr3DaysAvg) = md.getTokenPriceDetails(_curr);
        if ((mcrtp.mul(mcrtp)).div(DECIMAL1E08) >= 1) {
            tokenPrice = getSFx100000.mul(getGrowthStep.add(totalSupply));
            tokenPrice = tokenPrice.mul(mcrtp).mul(mcrtp).mul(100000);
            tokenPrice = tokenPrice.div(getGrowthStep);
        } else {
            tokenPrice = getSFx100000.mul(getGrowthStep.add(totalSupply));
            tokenPrice = tokenPrice.mul(10000 * 10000 * 100000);
            tokenPrice = tokenPrice.div(getGrowthStep);
        }

        tokenPrice = (tokenPrice.mul(getCurr3DaysAvg)).div(100);
    }

    /// @dev Adds MCR Data.
    ///      Checks if MCR is within valid thresholds in order to rule out any incorrect calculations
    function addMCRDataExtended(
        uint len,
        uint64 newMCRDate,
        bytes4[] curr,
        uint32 mcrE,
        uint32 mcrP,
        uint vF,
        uint32[] _threeDayAvg
    ) 
        internal
    {
        uint vtp = 0;
        uint lower = 0;
        uint lowerThreshold = 0;
        uint upperThreshold = 0;
        if (len > 1) {
            (vtp, ) = calVtpAndMCRtp();
            if (vtp >= vF) {
                upperThreshold = vtp.div(DECIMAL1E18.mul(md.getMinCap()));
                upperThreshold = upperThreshold.mul(100);
            } else {
                upperThreshold = vF.div(DECIMAL1E18.mul(md.getMinCap()));
                upperThreshold = upperThreshold.mul(100);
            }

            if (vtp > 0) {
                lower = (getAllSumAssurance().mul(100)).div(md.getShockParameter());
                lower = lower.mul(DECIMAL1E18);
            }
            if (lower > 0) {
                lowerThreshold = vtp.div(lower);
            }
        }
        if (len == 1 || (uint(mcrP).div(100)) >= lowerThreshold 
            && (uint(mcrP).div(100)) <= upperThreshold) {
            vtp = md.getLastMCRDate(); // due to stack to deep error,we are reusing already declared variable
            md.pushMCRData(uint32(mcrP), mcrE, vF, newMCRDate);
            for (uint i = 0; i < curr.length; i++) {
                md.updateCurr3DaysAvg(curr[i], _threeDayAvg[i]);
            }
            emit MCREvent(newMCRDate, block.number, curr, _threeDayAvg, mcrE, mcrP, vF);
            // Oraclize call for next MCR calculation
            if (vtp < newMCRDate) {
                callOracliseForMCR();
            }
        } else {
            p1.mcrOracliseFail(newMCRDate, md.getMCRFailTime());
        }
    }

}
