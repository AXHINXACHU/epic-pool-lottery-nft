// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol"; // Encodes metadata directly on-chain
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title AdvancedLotteryNFT
 * @notice Fixed supply of exactly 10 NFTs. On-chain named "EPIC NUMBER #1" to "#10".
 * 1 ETH mint price, 50/50 primary lottery split, dynamic marketplace fees, 75/25 secondary lottery split.
 */
contract AdvancedLotteryNFT is ERC721, VRFConsumerBaseV2Plus {
    using Strings for uint256;

    // --- Chainlink VRF Config ---
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public callbackGasLimit = 300000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;
    bool public payWithNativeEth = true; 

    enum RequestType { PRIMARY, SECONDARY }
    mapping(uint256 => RequestType) public requestTypes;

    // --- Strict 10-NFT Collection Supply Limits ---
    uint256 public constant TICKET_PRICE = 1 ether; // Exactly 1 ETH mint price
    uint256 public constant MAX_GLOBAL_SUPPLY = 10; // Hard cap at 10 tokens total
    uint256 public totalMintedSupply;
    address[10] public primaryMinters;
    bool public primaryDrawingInProgress;

    // --- Secondary Marketplace Logic ---
    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }
    
    mapping(uint256 => Listing) public marketplaceListings;
    
    uint256 public secondaryTransactionCount;
    uint256 public secondaryFeesAccumulated;
    address[10] public secondaryBuyers;
    bool public secondaryDrawingInProgress;

    // --- Events ---
    event TicketPurchased(address indexed buyer, uint256 indexed tokenId);
    event PrimaryDrawTriggered(uint256 requestId);
    event PrimaryWinnerPaid(address indexed winner, uint256 amount, address indexed owner, uint256 ownerAmount);
    
    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event SecondarySaleExecuted(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 feeDeducted);
    event SecondaryDrawTriggered(uint256 requestId);
    event SecondaryWinnerPaid(address indexed winner, uint256 amount, address indexed owner, uint256 ownerAmount);

    constructor(
        uint256 subscriptionId,
        bytes32 keyHash,
        address vrfCoordinator
    ) 
        ERC721("EpicPoolLottery", "EPL") 
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
    }

    // --- 1. Automated On-Chain Metadata (Generates "EPIC NUMBER #1-10") ---
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // Verifies the token exists

        // Dynamically compile the metadata JSON string on-chain
        bytes memory dataURI = abi.encodePacked(
            '{',
                '"name": "EPIC NUMBER #', tokenId.toString(), '",',
                '"description": "Exclusive Epic Pool Lottery Ticket NFT",',
                '"attributes": [{"trait_type": "Edition", "value": ', tokenId.toString(), '}]',
            '}'
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(dataURI)
            )
        );
    }

    // --- 2. Primary Mint Function (No Arguments Needed!) ---
    function buyTicket() external payable {
        require(totalMintedSupply < MAX_GLOBAL_SUPPLY, "All 10 NFTs have been minted! Primary market is closed forever.");
        require(!primaryDrawingInProgress, "Primary lottery drawing in progress, please wait.");
        require(msg.value == TICKET_PRICE, "Incorrect payment: Must send exactly 1 ETH.");

        primaryMinters[totalMintedSupply] = msg.sender;
        totalMintedSupply++;

        uint256 newTokenId = totalMintedSupply;
        _safeMint(msg.sender, newTokenId);

        emit TicketPurchased(msg.sender, newTokenId);

        // When the 10th ticket is sold, lock and draw the primary 50/50 lottery
        if (totalMintedSupply == MAX_GLOBAL_SUPPLY) {
            primaryDrawingInProgress = true;
            triggerVRFDraw(RequestType.PRIMARY);
        }
    }

    // --- 3. Secondary Marketplace Functions ---
    function listNFT(uint256 tokenId, uint256 price) external {
        require(ownerOf(tokenId) == msg.sender, "You do not own this NFT.");
        require(price > 0, "Price must be greater than zero.");
        
        marketplaceListings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            active: true
        });

        emit NFTListed(tokenId, msg.sender, price);
    }

    function buySecondaryNFT(uint256 tokenId) external payable {
        Listing memory listing = marketplaceListings[tokenId];
        require(listing.active, "NFT is not actively listed for sale.");
        require(msg.value == listing.price, "Please submit the exact sale price.");
        require(!secondaryDrawingInProgress, "Secondary drawing active. Marketplace briefly locked.");

        marketplaceListings[tokenId].active = false;

        // Dynamic fee calculation structure
        uint256 fee;
        if (msg.value > 1 ether) {
            fee = (msg.value * 10) / 100; // 10% fee if price > 1 ETH
        } else {
            fee = 0.1 ether; // Flat 0.1 ETH fee if price <= 1 ETH
        }

        require(msg.value > fee, "Sale price is lower than the required execution fee.");
        uint256 sellerProceeds = msg.value - fee;

        secondaryFeesAccumulated += fee;
        secondaryBuyers[secondaryTransactionCount] = msg.sender;
        secondaryTransactionCount++;

        _transfer(listing.seller, msg.sender, tokenId);

        (bool successSeller, ) = payable(listing.seller).call{value: sellerProceeds}("");
        require(successSeller, "Transfer to seller failed.");

        emit SecondarySaleExecuted(tokenId, listing.seller, msg.sender, listing.price, fee);

        // Triggers a secondary raffle whenever 10 marketplace sales clear
        if (secondaryTransactionCount == MAX_GLOBAL_SUPPLY) {
            secondaryDrawingInProgress = true;
            triggerVRFDraw(RequestType.SECONDARY);
        }
    }

    // --- 4. Internal Chainlink VRF Request Trigger ---
    function triggerVRFDraw(RequestType rType) internal {
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: payWithNativeEth})
                )
            })
        );

        requestTypes[requestId] = rType;
        
        if (rType == RequestType.PRIMARY) {
            emit PrimaryDrawTriggered(requestId);
        } else {
            emit SecondaryDrawTriggered(requestId);
        }
    }

    // --- 5. Chainlink Oracle Callback & Financial Split Distribution ---
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        RequestType rType = requestTypes[requestId];
        uint256 winningIndex = randomWords[0] % MAX_GLOBAL_SUPPLY;

        if (rType == RequestType.PRIMARY) {
            address primaryWinner = primaryMinters[winningIndex];
            
            // 50/50 split of the 10 ETH primary mint pot
            uint256 winnerPayout = 5 ether;
            uint256 ownerPayout = 5 ether;

            primaryDrawingInProgress = false; 

            (bool successWinner, ) = payable(primaryWinner).call{value: winnerPayout}("");
            require(successWinner, "Primary payout to winner failed.");

            (bool successOwner, ) = payable(owner()).call{value: ownerPayout}("");
            require(successOwner, "Primary payout to owner failed.");

            emit PrimaryWinnerPaid(primaryWinner, winnerPayout, owner(), ownerPayout);

        } else if (rType == RequestType.SECONDARY) {
            address secondaryWinner = secondaryBuyers[winningIndex];
            
            // 75/25 split of accumulated secondary marketplace fees
            uint256 totalPool = secondaryFeesAccumulated;
            uint256 winnerPayout = (totalPool * 75) / 100;
            uint256 ownerPayout = totalPool - winnerPayout;

            secondaryTransactionCount = 0;
            secondaryFeesAccumulated = 0;
            secondaryDrawingInProgress = false;

            (bool successSecWinner, ) = payable(secondaryWinner).call{value: winnerPayout}("");
            require(successSecWinner, "Secondary payout to winner failed.");

            (bool successSecOwner, ) = payable(owner()).call{value: ownerPayout}("");
            require(successSecOwner, "Secondary payout to owner failed.");

            emit SecondaryWinnerPaid(secondaryWinner, winnerPayout, owner(), ownerPayout);
        }
    }

    // --- Admin Configuration Switches ---
    function setPaymentMethod(bool _payWithNative) external onlyOwner {
        payWithNativeEth = _payWithNative;
    }

    function updateVRFConfig(uint32 _gasLimit, uint16 _confirmations) external onlyOwner {
        callbackGasLimit = _gasLimit;
        requestConfirmations = _confirmations;
    }
}
