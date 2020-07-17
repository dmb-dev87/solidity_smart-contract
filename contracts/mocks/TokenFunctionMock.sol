pragma solidity 0.5.7;

import "./Pool1Mock.sol";
import "../ClaimsData.sol";


contract TokenFunctionMock is TokenFunctions {

    function mint(address _member, uint _amount) external {
        tc.mint(_member, _amount);
    }

    function burnFrom(address _of, uint amount) external {
        tc.burnFrom(_of, amount);
    }

    function reduceLock(address _of, bytes32 _reason, uint256 _time) external {
        tc.reduceLock(_of, _reason, _time);
    }

    function burnLockedTokens(address _of, bytes32 _reason, uint256 _amount) external {
        tc.burnLockedTokens(_of, _reason, _amount);
    }

    function releaseLockedTokens(address _of, bytes32 _reason, uint256 _amount) 
        external 
     
    {
        tc.releaseLockedTokens(_of, _reason, _amount);
    }    

    function upgradeCapitalPool(address payable newPoolAddress) external {
        Pool1 p1 = Pool1(ms.getLatestAddress("P1"));
        p1.upgradeCapitalPool(newPoolAddress);
    }

    function setClaimSubmittedAtEPTrue(uint _index, bool _submit) external {
        ClaimsData cd = ClaimsData(ms.getLatestAddress("CD"));
        cd.setClaimSubmittedAtEPTrue(_index, _submit);
    }

    function transferCurrencyAsset(
        bytes4 _curr,
        address payable _address,
        uint _amount
    )
        public
        returns(bool)
    {
        Pool1Mock p1 = Pool1Mock(ms.getLatestAddress("P1"));
    
        return p1.transferCurrencyAssetToAddress(_curr, _address, _amount);
    }
}
