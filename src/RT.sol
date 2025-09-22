// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";

contract LMSRPredictionMarket is Ownable, ReentrancyGuard {

    enum MarketOutcome {
        UNRESOLVED,
        OPTION_A,
        OPTION_B
    }

    struct Market {
        string question;
        uint256 endTime;
        MarketOutcome outcome;
        string optionA;
        string optionB;
        bool resolved;
        mapping(address => uint256) optionASharesBalance;
        mapping(address => uint256) optionBSharesBalance;
        mapping(address => bool) hasClaimed;
        uint256 totalOptionAShares;
        uint256 totalOptionBShares;
        uint256 b;
        uint256 resolvedPayoutPool;
        uint256 propA;
        uint256 propB;
    }

    IERC20 public bettingToken;
    uint256 public marketCount;
    mapping(uint256 => Market) public markets;

    event MarketCreated(
        uint256 indexed marketId,
        string question,
        string optionA,
        string optionB,
        uint256 endTime
    );

    event SharesPurchased(
        uint256 indexed marketId,
        address indexed buyer,
        bool isOptionA,
        uint256 amount
    );

    event MarketResolved(uint256 indexed marketId, MarketOutcome outcome);

    event MarketRemoved(uint256 indexed marketId);

    event Claimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount
    );

    constructor(address _bettingToken) Ownable(msg.sender) {
        bettingToken = IERC20(_bettingToken);
        
    }


    function _canSetOwner() internal view virtual  returns (bool) {
        return msg.sender == owner();
    }


    function createMarket (
        string memory _question,
        string memory _optionA, 
        string memory _optionB, 
        uint256 _duration,
        uint256 _b
    ) external returns (uint256) {
        require(msg.sender == owner(), "Only owner can create markets");
        require(_duration > 0, "Duration must be positive");
        require(bytes(_optionA).length > 0 && bytes(_optionB).length > 0, "Options cannot be empty");
        uint256 marketId = marketCount++;
        Market storage market = markets[marketId];
        market.question = _question;
        market.optionA = _optionA;
        market.optionB = _optionB;
        market.endTime = block.timestamp + _duration;
        market.outcome = MarketOutcome.UNRESOLVED;
        market.b = market.b = _b > 0 ? _b : 100 * 1e18; // if _b is not set, default to 100 tokens worth in wei
        require(market.b > 0, "Liquidity parameter b must be positive");
        emit MarketCreated(marketId, _question, _optionA, _optionB, market.endTime);
        return marketId;
    }

    function _cost(uint256 bWei, uint256 qAWei, uint256 qBWei) internal pure returns (uint256) {
        UD60x18 b = ud(bWei);               
        UD60x18 qA = ud(qAWei);
        UD60x18 qB = ud(qBWei);

        UD60x18 termA = qA.div(b).exp();    
        UD60x18 termB = qB.div(b).exp();    
        UD60x18 sum = termA.add(termB);     
        UD60x18 lnSum = sum.ln();           
        UD60x18 result = b.mul(lnSum);      

        return result.unwrap();             
    }

    function buyShares(uint256 _marketId, bool _isOptionA, uint256 _amount ) external nonReentrant {
        Market storage market = markets[_marketId];
        require(block.timestamp < market.endTime, "Market trading period has ended");
        require(!market.resolved, "Market already resolved");
        require(_amount > 0, "Amount must be positive");

        uint256 price = this.getPriceForShares(_marketId, _isOptionA, _amount);
        require(bettingToken.transferFrom(msg.sender, address(this), price), "Token transfer failed");

        if (_isOptionA) {
            market.optionASharesBalance[msg.sender] += _amount;
            market.totalOptionAShares += _amount;
        } else {
            market.optionBSharesBalance[msg.sender] += _amount;
            market.totalOptionBShares += _amount;
        }

        // Update probabilities
        UD60x18 b     = ud(market.b);
        UD60x18 qA    = ud(market.totalOptionAShares);
        UD60x18 qB    = ud(market.totalOptionBShares);
        UD60x18 expA = qA.div(b).exp();
        UD60x18 expB = qB.div(b).exp();
        UD60x18 sum  = expA.add(expB);
        market.propA = expA.div(sum).mul(ud(1e18)).unwrap();
        market.propB = expB.div(sum).mul(ud(1e18)).unwrap();

        emit SharesPurchased(_marketId, msg.sender, _isOptionA, _amount);
    }

    function getPriceForShares(
    uint256 _marketId,
    bool _isOptionA,
    uint256 _amount
    ) external view returns (uint256 price) {
        Market storage market = markets[_marketId];
        uint256 oldQA = market.totalOptionAShares;
        uint256 oldQB = market.totalOptionBShares;
        uint256 newQA = oldQA;
        uint256 newQB = oldQB;
        if (_isOptionA) {
            newQA += _amount;
        } else {
            newQB += _amount;
        }
        uint256 costBefore = _cost(market.b, oldQA, oldQB);
        uint256 costAfter = _cost(market.b, newQA, newQB);
        price = costAfter - costBefore;
    }

    function resolveMarket(uint256 _marketId, MarketOutcome _outcome) external {
        require(msg.sender == owner(), "Only owner can resolve markets");
        Market storage market = markets[_marketId];
        require(block.timestamp >= market.endTime, "Market hasn't ended yet");
        require(!market.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");
        market.outcome = _outcome;
        market.resolved = true;
        market.resolvedPayoutPool = bettingToken.balanceOf(address(this));
        emit MarketResolved(_marketId, _outcome);
    }

    function removeMarket(uint256 _marketId) external {
        require(msg.sender == owner(), "Only owner can remove markets");
        require(_marketId < marketCount, "Market does not exist");
        delete markets[_marketId];
        emit MarketRemoved(_marketId);
    }

    function claimWinnings(uint256 _marketId) external nonReentrant {
        Market storage market = markets[_marketId];
        require(market.resolved, "Market not resolved yet");
        uint256 userShares;
        uint256 winningShares;
        if (market.outcome == MarketOutcome.OPTION_A) {
            userShares = market.optionASharesBalance[msg.sender];
            market.optionASharesBalance[msg.sender] = 0;
            winningShares = market.totalOptionAShares;
        } else if (market.outcome == MarketOutcome.OPTION_B) {
            userShares = market.optionBSharesBalance[msg.sender];
            market.optionBSharesBalance[msg.sender] = 0;
            winningShares = market.totalOptionBShares;
        } else {
            revert("Market outcome is not valid");
        }
        require(userShares > 0, "No winnings to claim");

        uint256 winnings = (userShares * market.resolvedPayoutPool) / winningShares;
        require(bettingToken.transfer(msg.sender, winnings), "Token transfer failed");
        emit Claimed(_marketId, msg.sender, winnings);
    }

    function getMarketInfo(
        uint256 _marketId
    ) external view returns (
        string memory question,
        string memory optionA,
        string memory optionB, 
        uint256 endTime,
        MarketOutcome outcome, 
        uint256 totalOptionAShares, 
        uint256 totalOptionBShares, 
        bool resolved,
        uint256 propA,
        uint256 propB
    ) 
    {
        Market storage market = markets[_marketId];
        return (
            market.question, 
            market.optionA, 
            market.optionB, 
            market.endTime, 
            market.outcome, 
            market.totalOptionAShares, 
            market.totalOptionBShares, 
            market.resolved,
            market.propA,
            market.propB
        );
    }

    function getSharesBalance(
        uint256 _marketId,
        address _user
    ) external view returns (uint256 optionAShares, uint256 optionBShares) {
        Market storage market = markets[_marketId];
        return (
            market.optionASharesBalance[_user],
            market.optionBSharesBalance[_user]
        );
    }

}
