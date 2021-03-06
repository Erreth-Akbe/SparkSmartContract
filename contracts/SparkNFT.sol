// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.4;

import "./IERC721Receiver.sol";
import "./IERC721Metadata.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";


contract SparkNFT is Context, ERC165, IERC721, IERC721Metadata{
    using Address for address;
    using Counters for Counters.Counter;
    Counters.Counter private _issueIds;
    /*
    Abstract struct Issue {
        uint8 royalty_fee;
        uint8 shilltimes;
        uint32 total_amount;
    }
    This structure records some common attributes of a series of NFTs:
        - `royalty_fee`: the proportion of royaltyes
        - `shilltimes`: the number of times a single NFT can been shared
        - `total_amount`: the total number of NFTs in the series
    To reduce gas cost, this structure is actually stored in the `father_id` attibute of root NFT
        - 0~31  `total_amount`
        - 48~56 `shilltimes`
        - 57~63 `total_amount`
    */

    struct Edition {
        // This structure stores NFT related information:
        //  - `father_id`: For root NFT it stores issue abstract sturcture
        //                 For other NFTs its stores the NFT Id of which NFT it `acceptShill` from
        // - `shillPrice`: The price should be paid when others `accpetShill` from this NFT
        // - remain_shill_times: The initial value is the shilltimes of the issue it belongs to
        //                       When others `acceptShill` from this NFT, it will subtract one until its value is 0  
        // - `owner`: record the owner of this NFT
        // - `ipfs_hash`: IPFS hash value of the URI where this NTF's metadata stores
        // - `transfer_price`: The initial value is zero
        //                   Set by `determinePrice` or `determinePriceAndApprove` before `transferFrom`
        //                   It will be checked wether equal to msg.value when `transferFrom` is called
        //                   After `transferFrom` this value will be set to zero
        // - `profit`: record the profit owner can claim (include royalty fee it should conduct to its father NFT)
        uint64 father_id;
        uint128 shillPrice;
        uint8 remain_shill_times;
        address owner;
        bytes32 ipfs_hash;
        uint128 transfer_price;
        uint128 profit;
    }

    // Emit when `determinePrice` success
    event DeterminePrice(
        uint64 indexed NFT_id,
        uint128 transfer_price
    );

    // Emit when `determinePriceAndApprove` success
    event DeterminePriceAndApprove(
        uint64 indexed NFT_id,
        uint128 transfer_price,
        address indexed to
    );

    // Emit when `publish` success
    // - `rootNFTId`: Record the Id of root NFT given to publisher 
    event Publish(
	    uint32 indexed issue_id,
        address indexed publisher,
        uint64 rootNFTId
    );

    // Emit when claimProfit success
    //- `amount`: Record the actual amount owner of this NFT received (profit - profit*royalty_fee/100)
    event Claim(
        uint64 indexed NFT_id,
        address indexed receiver,
        uint128 amount
    );

    //----------------------------------------------------------------------------------------------------
    /**
     * @dev Initializes the contract by setting a `name` and a `symbol` to the token collection.
     */
    constructor() {
        _name = "SparkNFT";
        _symbol = "SparkNFT";
    } 
    
   /**
     * @dev Create a issue and mint a root NFT for buyer acceptShill from
     *
     * Requirements:
     *
     * - `_first_sell_price`: The price should be paid when others `accpetShill` from this NFT
     * - `_royalty_fee`: The proportion of royaltyes, it represents the ratio of the father NFT's profit from the child NFT
     *                   Its value should <= 100
     * - `_shill_times`: the number of times a single NFT can been shared
     *                   Its value should <= 255
     * - `_ipfs_hash`: IPFS hash value of the URI where this NTF's metadata stores
     *
     * Emits a {Publish} event.
     * - Emitted {Publish} event contains root NFT id.
     */
    function publish(
        uint128 _first_sell_price,
        uint8 _royalty_fee,
        uint8 _shill_times,
        bytes32 _ipfs_hash
    ) 
        external 
    {
        require(_royalty_fee <= 100, "SparkNFT: Royalty fee should less than 100.");
        _issueIds.increment();
        require(_issueIds.current() <= type(uint32).max, "SparkNFT: value doesn't fit in 32 bits.");
        uint32 new_issue_id = uint32(_issueIds.current());
        uint64 rootNFTId = getNftIdByEditionIdAndIssueId(new_issue_id, 1);
        require(
            _checkOnERC721Received(address(0), msg.sender, rootNFTId, ""),
            "SparkNFT: transfer to non ERC721Receiver implementer"
        );
        Edition storage new_NFT = editions_by_id[rootNFTId];
        uint64 information;
        information = reWriteUint8InUint64(56, _royalty_fee, information);
        information = reWriteUint8InUint64(48, _shill_times, information);
        information += 1;
        new_NFT.father_id = information;
        new_NFT.remain_shill_times = _shill_times;
        new_NFT.shillPrice = _first_sell_price;
        new_NFT.owner = msg.sender;
        new_NFT.ipfs_hash = _ipfs_hash;
        _balances[msg.sender] += 1;
        emit Transfer(address(0), msg.sender, rootNFTId);
        emit Publish(
            new_issue_id,
            msg.sender,
            rootNFTId
        );
    }

    /**
     * @dev Buy a child NFT from the _NFT_id buyer input
     *
     * Requirements:
     *
     * - `_NFT_id`: _NFT_id the father NFT id buyer mint NFT from
     *              remain shill times of the NFT_id you input should greater than 0
     * Emits a {Ttansfer} event.
     * - Emitted {Transfer} event from 0x0 address to msg.sender, contain new NFT id.
     * - New NFT id will be generater by edition id and issue id
     *   0~31 edition id
     *   32~63 issue id
     */
    function acceptShill(
        uint64 _NFT_id
    ) 
        external 
        payable 
    {
        require(isEditionExist(_NFT_id), "SparkNFT: This NFT is not exist.");
        require(editions_by_id[_NFT_id].remain_shill_times > 0, "SparkNFT: There is no remain shill times for this NFT.");
        require(msg.value == editions_by_id[_NFT_id].shillPrice, "SparkNFT: incorrect ETH");
        _addProfit( _NFT_id, editions_by_id[_NFT_id].shillPrice);
        editions_by_id[_NFT_id].remain_shill_times -= 1;
        _mintNFT(_NFT_id, msg.sender);
        if (editions_by_id[_NFT_id].remain_shill_times == 0) {
            _mintNFT(_NFT_id, ownerOf(_NFT_id));
        }
    }

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *      
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `transfer_price` has been set, caller should give same value in msg.sender.
     * - Will call `claimProfit` before transfer and `transfer_price` will be set to zero after transfer. 
     * Emits a {TransferAsset} events
     */
    function transferFrom(address from, address to, uint256 tokenId) external payable override {
        _transfer(from, to, uint256toUint64(tokenId));
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external payable override{
       _safeTransfer(from, to, uint256toUint64(tokenId), "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata _data) external payable override {
        _safeTransfer(from, to, uint256toUint64(tokenId), _data);
    }
    
    /**
     * @dev Claim profit from reward pool of NFT.
     *      
     * Requirements:
     *
     * - `_NFT_id`: The NFT id of NFT caller claim, the profit will give to its owner.
     * - If its profit is zero the event {Claim} will not be emited.
     * Emits a {Claim} events
     */
    function claimProfit(uint64 _NFT_id) public {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        if (editions_by_id[_NFT_id].profit != 0) {
            uint128 amount = editions_by_id[_NFT_id].profit;
            editions_by_id[_NFT_id].profit = 0;
            if (!isRootNFT(_NFT_id)) {
                uint128 _royalty_fee = calculateFee(amount, getRoyaltyFeeByIssueId(getIssueIdByNFTId(_NFT_id)));
                _addProfit( getFatherByNFTId(_NFT_id), _royalty_fee);
                amount -= _royalty_fee;
            }
            payable(ownerOf(_NFT_id)).transfer(amount);
            emit Claim(
                _NFT_id,
                ownerOf(_NFT_id),
                amount
            );
        }
    }

    /**
     * @dev Determine NFT price before transfer.
     *
     * Requirements:
     *
     * - `_NFT_id`: transferred token id.
     * - `_price`: The amount of ETH should be payed for `_NFT_id`
     * Emits a {DeterminePrice} events
     */
    function determinePrice(
        uint64 _NFT_id,
        uint128 _price
    ) 
        public 
    {
        require(isEditionExist(_NFT_id), "SparkNFT: The NFT you want to buy is not exist.");
        require(msg.sender == ownerOf(_NFT_id), "SparkNFT: NFT's price should set by owner of it.");
        editions_by_id[_NFT_id].transfer_price = _price;
        emit DeterminePrice(_NFT_id, _price);
    }

    /**
     * @dev Determine NFT price before transfer.
     *
     * Requirements:
     *
     * - `_NFT_id`: transferred token id.
     * - `_price`: The amount of ETH should be payed for `_NFT_id`
     * - `_to`: The account address `approve` to. 
     * Emits a {DeterminePriceAndApprove} events
     */
    function determinePriceAndApprove(
        uint64 _NFT_id,
        uint128 _price,
        address _to
    ) 
        public 
    {
        determinePrice(_NFT_id, _price);
        approve(_to, _NFT_id);
        emit DeterminePriceAndApprove(_NFT_id, _price, _to);
    }

    /**
     * @dev See {IERC721-approve}.
     */
    function approve(address to, uint256 tokenId) public virtual override {
        address owner = ownerOf(tokenId);
        require(to != owner, "SparkNFT: approval to current owner");
        require(
            _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
            "SparkNFT: approve caller is not owner nor approved for all"
        );

        _approve(to, uint256toUint64(tokenId));
    }

    /**
     * @dev See {IERC721-setApprovalForAll}.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override {
        require(operator != _msgSender(), "SparkNFT: approve to caller");
        _operatorApprovals[_msgSender()][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC721-balanceOf}.
     */
    function balanceOf(address owner) public view virtual override returns (uint256) {
        require(owner != address(0), "SparkNFT: balance query for the zero address");
        return _balances[owner];
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = editions_by_id[uint256toUint64(tokenId)].owner;
        require(owner != address(0), "SparkNFT: owner query for nonexistent token");
        return owner;
    }

    /**
     * @dev See {IERC721Metadata-name}.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev See {IERC721-getApproved}.
     */
    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        require(isEditionExist(uint256toUint64(tokenId)), "SparkNFT: approved query for nonexistent token");

        return _tokenApprovals[uint256toUint64(tokenId)];
    }

    /**
     * @dev See {IERC721-isApprovedForAll}.
     */
    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /** 
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(isEditionExist(uint256toUint64(tokenId)), "SparkNFT: URI query for nonexistent token");
        
        bytes32 _ipfs_hash = editions_by_id[uint256toUint64(tokenId)].ipfs_hash;
        string memory encoded_hash = _toBase58String(_ipfs_hash);
        string memory base = _baseURI();
        return string(abi.encodePacked(base, encoded_hash));
    }

    /**
     * @dev Query is issue exist.
     *
     * Requirements:
     * - `_issue_id`: The id of the issue queryed.
     * Return a bool value.
     */
    function isIssueExist(uint32 _issue_id) public view returns (bool) {
        return isEditionExist(getRootNFTIdByIssueId(_issue_id));
    }

    /**
     * @dev Query is edition exist.
     *
     * Requirements:
     * - `_NFT_id`: The id of the edition queryed.
     * Return a bool value.
     */
    function isEditionExist(uint64 _NFT_id) public view returns (bool) {
        return (editions_by_id[_NFT_id].owner != address(0));
    }

    /**
     * @dev Query the amount of ETH a NFT can be claimed.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return the value this NFT can be claimed.
     * If the NFT is not root NFT, this value will subtract royalty fee percent.
     */
    function getProfitByNFTId(uint64 _NFT_id) public view returns (uint128){
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        uint128 amount = editions_by_id[_NFT_id].profit;
        if (!isRootNFT(_NFT_id)) {
            uint128 _royalty_fee = calculateFee(editions_by_id[_NFT_id].profit, getRoyaltyFeeByIssueId(getIssueIdByNFTId(_NFT_id)));
            amount -= _royalty_fee;
        }
        return amount;
    }

    /**
     * @dev Query royalty fee percent of an issue.
     *  
     * Requirements:
     * - `_issue_id`: The id of the issue queryed.
     * Return royalty fee percent of this issue.
     */
    function getRoyaltyFeeByIssueId(uint32 _issue_id) public view returns (uint8) {
        require(isIssueExist(_issue_id), "SparkNFT: This issue is not exist.");
        return getUint8FromUint64(56, editions_by_id[getRootNFTIdByIssueId(_issue_id)].father_id);
    }

    /**
     * @dev Query max shill times of an issue.
     *  
     * Requirements:
     * - `_issue_id`: The id of the issue queryed.
     * Return max shill times of this issue.
     */
    function getShillTimesByIssueId(uint32 _issue_id) public view returns (uint8) {
        require(isIssueExist(_issue_id), "SparkNFT: This issue is not exist.");
        return getUint8FromUint64(48, editions_by_id[getRootNFTIdByIssueId(_issue_id)].father_id);
    }

    /**
     * @dev Query total NFT number of an issue.
     *  
     * Requirements:
     * - `_issue_id`: The id of the issue queryed.
     * Return total NFT number of this issue.
     */
    function getTotalAmountByIssueId(uint32 _issue_id) public view returns (uint32) {
        require(isIssueExist(_issue_id), "SparkNFT: This issue is not exist.");
        return getBottomUint32FromUint64(editions_by_id[getRootNFTIdByIssueId(_issue_id)].father_id);
    }

    /**
     * @dev Query the id of this NFT's father NFT.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * - This NFT should exist and not be root NFT.
     * Return the father NFT id of this NFT.
     */
    function getFatherByNFTId(uint64 _NFT_id) public view returns (uint64) {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        require(!isRootNFT(_NFT_id), "SparkNFT: Root NFT doesn't have father NFT.");
        return editions_by_id[_NFT_id].father_id;
    }    
    
    /**
     * @dev Query transfer_price of this NFT.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return transfer_price of this NFT.
     */
    function getTransferPriceByNFTId(uint64 _NFT_id) public view returns (uint128) {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].transfer_price;
    }

    /**
     * @dev Query shillPrice of this NFT.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return shillPrice of this NFT.
     */
    function getShillPriceByNFTId(uint64 _NFT_id) public view returns (uint128) {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].shillPrice;
    }

    /**
     * @dev Query remain_shill_times of this NFT.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return remain_shill_times of this NFT.
     */
    function getRemainShillTimesByNFTId(uint64 _NFT_id) public view returns (uint8) {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        return editions_by_id[_NFT_id].remain_shill_times;
    }

    /**
     * @dev Query depth of this NFT.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return depth of this NFT.
     */
    function getDepthByNFTId(uint64 _NFT_id) public view returns (uint64) {
        require(isEditionExist(_NFT_id), "SparkNFT: Edition is not exist.");
        uint64 depth = 0;
        for (depth = 0; !isRootNFT(_NFT_id); _NFT_id = getFatherByNFTId(_NFT_id)) {
            depth += 1;
        }
        return depth;
    }
    
    /**
     * @dev Calculate NFT id by issue id and edition id.
     *  
     * Requirements:
     * - `_issue_id`: The issue id of the NFT caller want to get.
     * - `_edition_id`: The edition id of the NFT caller want to get.
     * Return NFT id.
     */
    function getNftIdByEditionIdAndIssueId(uint32 _issue_id, uint32 _edition_id) internal pure returns (uint64) {
        return (uint64(_issue_id)<<32)|uint64(_edition_id);
    }

    /**
     * @dev Query is this NFT is root NFT by check is its edition id is 1.
     *  
     * Requirements:
     * - `_NFT_id`: The id of the NFT queryed.
     * Return a bool value to indicate wether this NFT is root NFT.
     */
    function isRootNFT(uint64 _NFT_id) public pure returns (bool) {
        return getBottomUint32FromUint64(_NFT_id) == uint32(1);
    }

    /**
     * @dev Query root NFT id by issue id.
     *  
     * Requirements:
     * - `_issue_id`: The id of the issue queryed.
     * Return a bool value to indicate wether this NFT is root NFT.
     */
    function getRootNFTIdByIssueId(uint32 _issue_id) public pure returns (uint64) {
        return (uint64(_issue_id)<<32 | uint64(1));
    }

    /**
     * @dev Query loss ratio of this contract.
     *  
     * Return loss ratio of this contract.
     */
    function getLossRatio() public pure returns (uint8) {
        return loss_ratio;
    }
    
    /**
     * @dev Calculate issue id by NFT id.
     *  
     * Requirements:
     * - `_NFT_id`: The NFT id of the NFT caller want to get.
     * Return issue id.
     */
    function getIssueIdByNFTId(uint64 _NFT_id) public pure returns (uint32) {
        return uint32(_NFT_id >> 32);
    }
    
    /**
     * @dev Calculate edition id by NFT id.
     *  
     * Requirements:
     * - `_NFT_id`: The NFT id of the NFT caller want to get.
     * Return edition id.
     */
    function getEditionIdByNFTId(uint64 _NFT_id) public pure returns (uint32) {
        return getBottomUint32FromUint64(_NFT_id);
    }
    // Token name
    string private _name;

    // Token symbol
    string private _symbol;
    uint8 constant private loss_ratio = 90;
    // Mapping owner address to token count
    mapping(address => uint64) private _balances;
    // Mapping from token ID to approved address
    mapping(uint64 => address) private _tokenApprovals;
    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping (uint64 => Edition) private editions_by_id;

    bytes constant private sha256MultiHash = hex"1220"; 
    bytes constant private ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

     /**
     * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
     * The call is not executed if the target address is not a contract.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId uint256 ID of the token to be transferred
     * @param _data bytes optional data to send along with the call
     * @return bool whether the call correctly returned the expected magic value
     */
    function _checkOnERC721Received(
        address from,
        address to,
        uint64 tokenId,
        bytes memory _data
    ) 
        private 
        returns (bool) 
    {
        if (to.isContract()) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, _data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("SparkNFT: transfer to non ERC721Receiver implementer");
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    /**
     * @dev Sets `_tokenURI` as the tokenURI of `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function _setTokenURI(uint64 tokenId, bytes32 ipfs_hash) internal virtual {
        require(isEditionExist(tokenId), "SparkNFT: URI set of nonexistent token");
        editions_by_id[tokenId].ipfs_hash = ipfs_hash;
    }
    
     /**
     * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
     * The call is not executed if the target address is not a contract.
     *
     * @param _NFT_id NFT id of father NFT
     * @param _owner indicate the address new NFT transfer to
     * @return a uint64 store new NFT id
     **/
    function _mintNFT(
        uint64 _NFT_id,
        address _owner
    ) 
        internal 
        returns (uint64) 
    {
        uint32 _issue_id = getIssueIdByNFTId(_NFT_id);
        _addTotalAmount(_issue_id);
        uint32 new_edition_id = getTotalAmountByIssueId(_issue_id);
        uint64 new_NFT_id = getNftIdByEditionIdAndIssueId(_issue_id, new_edition_id);
        require(
            _checkOnERC721Received(address(0), _owner, new_NFT_id, ""),
            "SparkNFT: transfer to non ERC721Receiver implementer"
        );
        Edition storage new_NFT = editions_by_id[new_NFT_id];
        new_NFT.remain_shill_times = getShillTimesByIssueId(_issue_id);
        new_NFT.father_id = _NFT_id;
        new_NFT.shillPrice = calculateFee(editions_by_id[_NFT_id].shillPrice, loss_ratio);
        new_NFT.owner = _owner;
        new_NFT.ipfs_hash = editions_by_id[_NFT_id].ipfs_hash;
        _balances[_owner] += 1;
        emit Transfer(address(0), _owner, new_NFT_id);
        return new_NFT_id;
    }

    /**
     * @dev Internal function to clear approve and transfer_price
     *
     * @param _NFT_id NFT id of father NFT
     **/
    function _afterTokenTransfer (uint64 _NFT_id) internal {
        // Clear approvals from the previous owner
        _approve(address(0), _NFT_id);
        editions_by_id[_NFT_id].transfer_price = 0;
    }

    /**
     * @dev Internal function to support transfer `tokenId` from `from` to `to`.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId uint256 ID of the token to be transferred
     * Emits a {Transfer} event.
     */
    function _transfer(
        address from,
        address to,
        uint64 tokenId
    ) 
        internal 
        virtual 
    {
        require(ownerOf(tokenId) == from, "SparkNFT: transfer of token that is not own");
        require(_isApprovedOrOwner(_msgSender(), tokenId), "SparkNFT: transfer caller is not owner nor approved");
        require(to != address(0), "SparkNFT: transfer to the zero address");
        if (msg.sender != ownerOf(tokenId)) {
            require(msg.value == editions_by_id[tokenId].transfer_price, "SparkNFT: not enought ETH");
            _addProfit(tokenId, editions_by_id[tokenId].transfer_price);
            claimProfit(tokenId);
        }
        else {
            claimProfit(tokenId);
        }
        _afterTokenTransfer(tokenId);
        _balances[from] -= 1;
        _balances[to] += 1;
        editions_by_id[tokenId].owner = to;
        emit Transfer(from, to, tokenId);
    }

     /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * `_data` is additional data, it has no specified format and it is sent in call to `to`.
     *
     * This internal function is equivalent to {safeTransferFrom}, and can be used to e.g.
     * implement alternative mechanisms to perform token transfer, such as signature-based.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function _safeTransfer(
        address from,
        address to,
        uint64 tokenId,
        bytes memory _data
    ) 
        internal 
        virtual 
    {
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, _data), "SparkNFT: transfer to non ERC721Receiver implementer");
    }

    /**
     * @dev Approve `to` to operate on `tokenId`
     *
     * Emits a {Approval} event.
     */
    function _approve(address to, uint64 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function _addProfit(uint64 _NFT_id, uint128 _increase) internal {
        editions_by_id[_NFT_id].profit = editions_by_id[_NFT_id].profit+_increase;
    }

    function _subProfit(uint64 _NFT_id, uint128 _decrease) internal {
        editions_by_id[_NFT_id].profit = editions_by_id[_NFT_id].profit-_decrease;
    }

    function _addTotalAmount(uint32 _issue_id) internal {
        require(getTotalAmountByIssueId(_issue_id) < type(uint32).max, "SparkNFT: There is no left in this issue.");
        editions_by_id[getRootNFTIdByIssueId(_issue_id)].father_id += 1;
    }

    function _isApprovedOrOwner(address spender, uint64 tokenId) internal view virtual returns (bool) {
        require(isEditionExist(tokenId), "SparkNFT: operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }
        
    function _baseURI() internal pure returns (string memory) {
        return "https://ipfs.io/ipfs/";
    } 

    function getUint8FromUint64(uint8 position, uint64 data64) internal pure returns (uint8 data8) {
        // (((1 << size) - 1) & base >> position)
        assembly {
            data8 := and(sub(shl(8, 1), 1), shr(position, data64))
        }
    }
    
    function getBottomUint32FromUint64(uint64 data64) internal pure returns (uint32 data32) {
        // (((1 << size) - 1) & base >> position)
        assembly {
            data32 := and(sub(shl(32, 1), 1), data64)
        }
    }
    
    function reWriteUint8InUint64(uint8 position, uint8 data8, uint64 data64) internal pure returns (uint64 boxed) {
        assembly {
            // mask = ~((1 << 8 - 1) << position)
            // _box = (mask & _box) | ()data << position)
            boxed := or( and(data64, not(shl(position, sub(shl(8, 1), 1)))), shl(position, data8))
        }
    }

    function uint256toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SparkNFT: value doesn't fit in 64 bits");
        return uint64(value);
    }
    
    function calculateFee(uint128 _amount, uint8 _fee_percent) internal pure returns (uint128) {
        return _amount*_fee_percent/10**2;
    }

    function _toBase58String(bytes32 con) internal pure returns (string memory) {
        
        bytes memory source = bytes.concat(sha256MultiHash,con);

        uint8[] memory digits = new uint8[](64); //TODO: figure out exactly how much is needed
        digits[0] = 0;
        uint8 digitlength = 1;
        for (uint256 i = 0; i<source.length; ++i) {
        uint carry = uint8(source[i]);
        for (uint256 j = 0; j<digitlength; ++j) {
            carry += uint(digits[j]) * 256;
            digits[j] = uint8(carry % 58);
            carry = carry / 58;
        }
        
        while (carry > 0) {
            digits[digitlength] = uint8(carry % 58);
            digitlength++;
            carry = carry / 58;
        }
        }
        //return digits;
        return string(toAlphabet(reverse(truncate(digits, digitlength))));
    }

    function toAlphabet(uint8[] memory indices) internal pure returns (bytes memory) {
        bytes memory output = new bytes(indices.length);
        for (uint256 i = 0; i<indices.length; i++) {
            output[i] = ALPHABET[indices[i]];
        }
        return output;
    }
    
    function truncate(uint8[] memory array, uint8 length) internal pure returns (uint8[] memory) {
        uint8[] memory output = new uint8[](length);
        for (uint256 i = 0; i<length; i++) {
            output[i] = array[i];
        }
        return output;
    }
  
    function reverse(uint8[] memory input) internal pure returns (uint8[] memory) {
        uint8[] memory output = new uint8[](input.length);
        for (uint256 i = 0; i<input.length; i++) {
            output[i] = input[input.length-1-i];
        }
        return output;
    }
}
