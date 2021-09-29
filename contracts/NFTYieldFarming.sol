// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "./IERC20.sol";
import { ERC20Token } from "./ERC20Token.sol";
//import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/EnumerableSet.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice - NFTYieldFarming (ERC20 version) is the master contract of Token. This contract can make Token.
 */
contract NFTYieldFarmingOnBSC is Ownable {
    using SafeMath for uint256;
    //using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each NFT pool.
    struct NFTPoolInfo {
        IERC721 nftToken;    /// NFT token as a target to stake
        IERC20 lpToken;      /// LP token (ERC20) to be staked
        uint256 allocPoint;  /// How many allocation points assigned to this pool. Tokens to distribute per block.
        uint256 lastRewardBlock; // Last block number that Tokens distribution occurs.
        uint256 accTokenPerShare; // Accumulated Tokens per share, times 1e12. See below.
    }
    
    // The  Token (ERC20 version)
    ERC20Token public Token;
    
    // Block number when bonus Token period ends.
    uint256 public bonusEndBlock;
    
    // Token tokens created per block.
    uint256 public TokenPerBlock;
    
    // Bonus muliplier for early Token makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    
    // Info of each pool.
    NFTPoolInfo[] public nftPoolInfo;
    
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    
    // The block number when Token mining starts.
    uint256 public startBlock;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        ERC20Token _Token,        
        uint256 _TokenPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        Token = _Token;
        TokenPerBlock = _TokenPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function nftPoolLength() external view returns (uint256) {
        return nftPoolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addNFTPool(
        IERC721 _nftToken,   /// NFT token as a target to stake
        IERC20 _lpToken,     /// LP token (ERC20) to be staked
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        nftPoolInfo.push(
            NFTPoolInfo({
                nftToken: _nftToken,
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTokenPerShare: 0
            })
        );

        totalAllocPoint = totalAllocPoint.add(_allocPoint);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending Tokens on frontend.
    function pendingToken(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        NFTPoolInfo storage pool = nftPoolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 TokenReward =
                multiplier.mul(TokenPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accTokenPerShare = accTokenPerShare.add(
                TokenReward.mul(1e12).div(lpSupply)
            );
        }

        return user.amount.mul(accTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = nftPoolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        NFTPoolInfo storage pool = nftPoolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 TokenReward =
            multiplier.mul(TokenPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );
        Token.mint(address(this), TokenReward);    /// [Note]: mint method can be used by only owner
        pool.accTokenPerShare = pool.accTokenPerShare.add(
            TokenReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit (Stake) LP tokens to the NFTYieldFarming contract for Token allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        NFTPoolInfo storage pool = nftPoolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accTokenPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            safeTokenTransfer(msg.sender, pending);
        }
        pool.lpToken.transferFrom(  /// [Note]: Using ERC20
            address(msg.sender),
            address(this),
            _amount
        );
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw (Un-Stake) LP tokens from the NFTYieldFarming contract.
    function withdraw(uint256 _pid, uint256 _amount) public {
        NFTPoolInfo storage pool = nftPoolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accTokenPerShare).div(1e12).sub(
                user.rewardDebt
            );
        safeTokenTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e12);
        pool.lpToken.transfer(address(msg.sender), _amount);  /// [Note]: Using ERC20
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Safe Token transfer function, just in case if rounding error causes pool to not have enough Token.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 TokenBal = Token.balanceOf(address(this));
        if (_amount > TokenBal) {
            Token.transfer(_to, TokenBal);
        } else {
            Token.transfer(_to, _amount);
        }
    }
}
