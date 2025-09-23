"use client";

import { Button } from "./ui/button";
import { Input } from "./ui/input";
import { useState, useRef, useEffect, useCallback, useMemo } from "react";
import {
useAccount,
useReadContract,
useWriteContract,
useWaitForTransactionReceipt,
useSendCalls,
useWaitForCallsStatus,
useConnectorClient,
type BaseError,
} from "wagmi";
import {
V2contractAddress,
V2contractAbi,
tokenAddress,
tokenAbi,
PolicastViews,
PolicastViewsAbi,
} from "@/constants/contract";
import { encodeFunctionData } from "viem";
import { Loader2, TrendingDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { useToast } from "@/components/ui/use-toast";
import { MarketV2 } from "@/types/types";

interface MarketV2SellInterfaceProps {
marketId: number;
market: MarketV2;
userShares: { [optionId: number]: bigint };
onSellComplete?: () => void;
}

type SellingStep =
| "initial"
| "amount"
| "confirm"
| "processing"
| "sellSuccess";

// Helper function to calculate implied probability from token price
function calculateProbability(tokenPrice: bigint): number {
// PolicastViews returns token prices (0-100 range), convert to percentage
const price = Number(tokenPrice) / 1e18;
return Math.max(0, Math.min(100, price));
}

// Helper function to calculate implied odds
function calculateOdds(tokenPrice: bigint): number {
// Convert token price to probability and then to odds
const probability = Number(tokenPrice) / (100 \* 1e18); // Convert back to 0-1 range
if (probability <= 0) return 0;
return 1 / probability;
}

// Format price with proper decimals
function formatPrice(price: bigint, decimals: number = 18): string {
const formatted = Number(price) / Math.pow(10, decimals);
if (formatted < 0.01) return formatted.toFixed(4);
if (formatted < 1) return formatted.toFixed(3);
return formatted.toFixed(2);
}

// Format shares amount
function formatShares(shares: bigint): string {
const formatted = Number(shares) / Math.pow(10, 18);
return formatted.toFixed(2);
}

// Convert internal probability to token price (for fallback scenarios)
function probabilityToTokenPrice(probability: bigint): bigint {
// Convert internal probability (0-1 range scaled by 1e18) to token price (0-100 range)
const PAYOUT_PER_SHARE = 100n _ (10n \*\* 18n); // 100 tokens per share
return (probability _ PAYOUT_PER_SHARE) / 1000000000000000000n;
}

export function MarketV2SellInterface({
marketId,
market,
userShares,
onSellComplete,
}: MarketV2SellInterfaceProps) {
const { address: accountAddress, isConnected, connector } = useAccount();
const { data: connectorClient } = useConnectorClient();
const {
data: hash,
writeContractAsync,
isPending: isWritePending,
error: writeError,
} = useWriteContract();
const {
isLoading: isConfirmingTx,
isSuccess: isTxConfirmed,
error: txError,
} = useWaitForTransactionReceipt({
hash,
});
const { toast } = useToast();

const [isSelling, setIsSelling] = useState(false);
const [isVisible, setIsVisible] = useState(true);
const [containerHeight, setContainerHeight] = useState("auto");
const contentRef = useRef<HTMLDivElement>(null);
const inputRef = useRef<HTMLInputElement>(null);

const [selectedOptionId, setSelectedOptionId] = useState<number | null>(null);
const [sellAmount, setSellAmount] = useState<string>("");
const [sellingStep, setSellingStep] = useState<SellingStep>("initial");
const [isProcessing, setIsProcessing] = useState(false);
const [error, setError] = useState<string | null>(null);
const [lastProcessedHash, setLastProcessedHash] = useState<string | null>(
null
);

// Slippage config (basis points)
const SELL_SLIPPAGE_BPS = 50; // 0.5%

// Shares utils
function sharesToWei(amount: string): bigint {
if (!amount) return 0n;
const [i, f = ""] = amount.split(".");
const frac = (f + "0".repeat(18)).slice(0, 18);
return BigInt((i || "0") + frac);
}

function withNegBuffer(x: bigint, bps: number = SELL_SLIPPAGE_BPS): bigint {
const denom = 10000n;
return (x \* (denom - BigInt(bps))) / denom;
}

// Token information//
const { data: tokenSymbol } = useReadContract({
address: tokenAddress,
abi: tokenAbi,
functionName: "symbol",
});

const { data: tokenDecimals } = useReadContract({
address: tokenAddress,
abi: tokenAbi,
functionName: "decimals",
});

// Fetch token prices from PolicastViews
const { data: tokenPrices, refetch: refetchTokenPrices } = useReadContract({
address: PolicastViews,
abi: PolicastViewsAbi,
functionName: "getMarketPricesInTokens",
args: [BigInt(marketId)],
query: {
refetchInterval: 2000, // Refresh every 2 seconds
},
});

// Fetch current price for selected option
const { data: optionData, refetch: refetchOptionData } = useReadContract({
address: V2contractAddress,
abi: V2contractAbi,
functionName: "getMarketOption",
args: [BigInt(marketId), BigInt(selectedOptionId || 0)],
query: { enabled: selectedOptionId !== null },
});

// Compute quantity in 1e18 shares
const quantityInShares = useMemo(() => sharesToWei(sellAmount), [sellAmount]);

// On-chain sell quote (rawRefund, fee, netRefund, avgPricePerShare)
const { data: sellQuote } = useReadContract({
address: PolicastViews,
abi: PolicastViewsAbi,
functionName: "quoteSell",
args:
selectedOptionId === null || quantityInShares <= 0n
? undefined
: [BigInt(marketId), BigInt(selectedOptionId), quantityInShares],
query: {
enabled: selectedOptionId !== null && quantityInShares > 0n,
refetchInterval: 2000,
},
});

const rawRefundFromQuote = (sellQuote?.[0] ?? 0n) as bigint;
const feeFromQuote = (sellQuote?.[1] ?? 0n) as bigint;
const netRefundFromQuote = (sellQuote?.[2] ?? 0n) as bigint;
const avgPricePerShareFromQuote = (sellQuote?.[3] ?? 0n) as bigint;

// Calculate estimated revenue using token prices from PolicastViews
const estimatedRevenue = useMemo(() => {
// Prefer exact on-chain quote if available
if (netRefundFromQuote > 0n) return netRefundFromQuote;

// Fallback to simple linear estimate if quote not ready
if (!tokenPrices || selectedOptionId === null || !sellAmount || parseFloat(sellAmount) <= 0) return 0n;
const tokenPrice = (tokenPrices as readonly bigint[])[selectedOptionId];
const quantity = sharesToWei(sellAmount);
const rawRefund = (tokenPrice _ quantity) / 1000000000000000000n;
const fee = (rawRefund _ 200n) / 10000n;
return rawRefund - fee;
}, [netRefundFromQuote, tokenPrices, selectedOptionId, sellAmount]);

// Calculate minimum price with slippage protection (uses SELL_SLIPPAGE_BPS)
const calculateMinPrice = useCallback((pricePerShare: bigint): bigint => {
return withNegBuffer(pricePerShare, SELL_SLIPPAGE_BPS);
}, []);

// Handle sell transaction
const handleSell = useCallback(async () => {
if (
!accountAddress ||
selectedOptionId === null ||
!sellAmount ||
!tokenDecimals ||
!estimatedRevenue
)
return;

    try {
      setIsProcessing(true);
      setSellingStep("processing");

      const sellAmountBigInt = quantityInShares;

      // Use on-chain avg price per share when available
      const avgPricePerShare =
        avgPricePerShareFromQuote > 0n
          ? avgPricePerShareFromQuote
          : sellAmountBigInt > 0n
          ? ((estimatedRevenue as bigint) * 1000000000000000000n) / sellAmountBigInt
          : 0n;
      const minPricePerShare = calculateMinPrice(avgPricePerShare);
      const minTotalProceeds = netRefundFromQuote > 0n ? withNegBuffer(netRefundFromQuote) : withNegBuffer(estimatedRevenue as bigint);

      console.log("=== V2 SELL TRANSACTION ===");
      console.log("Market ID:", marketId);
      console.log("Option ID:", selectedOptionId);
      console.log("Sell Amount:", sellAmountBigInt.toString());
      console.log("Estimated Revenue:", estimatedRevenue.toString());
      console.log("Avg Price Per Share:", avgPricePerShare.toString());
      console.log("Min Price Per Share:", minPricePerShare.toString());

      await writeContractAsync({
        address: V2contractAddress,
        abi: V2contractAbi,
        functionName: "sellShares",
        args: [
          BigInt(marketId),
          BigInt(selectedOptionId),
          sellAmountBigInt,
          minPricePerShare,
          minTotalProceeds, // _minTotalProceeds (net proceeds with slippage buffer)
        ],
      });
    } catch (err) {
      console.error("Sell transaction failed:", err);
      setError("Sell transaction failed. Please try again.");
      setSellingStep("initial");
    } finally {
      setIsProcessing(false);
    }

}, [
accountAddress,
selectedOptionId,
sellAmount,
tokenDecimals,
estimatedRevenue,
sellQuote,
calculateMinPrice,
marketId,
writeContractAsync,
]);

// Handle transaction confirmation
useEffect(() => {
if (isTxConfirmed && hash && hash !== lastProcessedHash) {
setLastProcessedHash(hash);
setSellingStep("sellSuccess");
setSellAmount("");
setSelectedOptionId(null);

      toast({
        title: "Shares Sold Successfully!",
        description: `Your shares have been sold and tokens transferred to your wallet.`,
      });

      // Call completion callback
      if (onSellComplete) {
        onSellComplete();
      }

      // Refresh data
      refetchOptionData();
      refetchTokenPrices();

      // Reset after delay
      setTimeout(() => {
        setSellingStep("initial");
        setError(null);
      }, 3000);
    }

}, [
isTxConfirmed,
hash,
lastProcessedHash,
toast,
onSellComplete,
refetchOptionData,
]);

// Handle errors
useEffect(() => {
if (writeError || txError) {
const errorMessage =
(writeError as BaseError)?.shortMessage ||
(txError as BaseError)?.shortMessage ||
"Transaction failed";
setError(errorMessage);
setSellingStep("initial");
setIsProcessing(false);
}
}, [writeError, txError]);

// Auto-focus input when step changes
useEffect(() => {
if (sellingStep === "amount" && inputRef.current) {
setTimeout(() => inputRef.current?.focus(), 100);
}
}, [sellingStep]);

// Update container height smoothly
useEffect(() => {
if (contentRef.current) {
setContainerHeight(`${contentRef.current.scrollHeight}px`);
}
}, [sellingStep, selectedOptionId, error]);

const currentPrice =
tokenPrices && selectedOptionId !== null
? (tokenPrices as readonly bigint[])[selectedOptionId]
: optionData?.[4]
? probabilityToTokenPrice(optionData[4] as bigint)
: 0n;
const userSharesForOption =
selectedOptionId !== null ? userShares[selectedOptionId] || 0n : 0n;
const maxSellAmount = Number(userSharesForOption) / Math.pow(10, 18);

// Use AMM estimated revenue instead of simple calculation
const estimatedRevenueFormatted = estimatedRevenue
? Number(estimatedRevenue) / Math.pow(10, 18)
: 0;

// Get options with user shares using token prices
const optionsWithShares = market.options
.map((option, index) => {
const tokenPrice = tokenPrices
? (tokenPrices as readonly bigint[])[index]
: probabilityToTokenPrice(option.currentPrice);

      return {
        id: index,
        name: option.name,
        shares: userShares[index] || 0n,
        currentPrice: tokenPrice,
      };
    })
    .filter((option) => option.shares > 0n);

if (!isVisible) return null;

return (

<div
className="transition-all duration-300 ease-in-out"
style={{ minHeight: containerHeight }} >
<div ref={contentRef} className="space-y-3 md:space-y-4">
{/* Header */}
<div className="flex items-center gap-2 text-red-600">
<TrendingDown className="h-3 w-3 md:h-4 md:w-4" />
<span className="font-medium text-sm md:text-base">Sell Shares</span>
</div>

        {/* Error Display */}
        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-2 md:p-3">
            <p className="text-red-700 text-xs md:text-sm">{error}</p>
          </div>
        )}

        {/* Step 1: Option Selection */}
        {sellingStep === "initial" && (
          <div className="space-y-2 md:space-y-3">
            <p className="text-xs md:text-sm text-gray-600">
              Select which option shares you want to sell:
            </p>

            {optionsWithShares.length === 0 ? (
              <div className="text-center py-3 md:py-4 text-gray-500 text-sm">
                You don&apos;t own any shares in this market.
              </div>
            ) : (
              <div className="space-y-2">
                {optionsWithShares.map((option) => (
                  <button
                    key={option.id}
                    onClick={() => {
                      setSelectedOptionId(option.id);
                      setSellingStep("amount");
                    }}
                    className="w-full p-2 md:p-3 text-left border border-gray-200 rounded-lg hover:border-red-300 hover:bg-red-50 transition-colors"
                  >
                    <div className="flex justify-between items-center">
                      <div>
                        <div className="font-medium text-sm md:text-base">
                          {option.name}
                        </div>
                        <div className="text-xs md:text-sm text-gray-600">
                          Your shares: {formatShares(option.shares)}
                        </div>
                      </div>
                      <div className="text-right">
                        <div className="text-xs md:text-sm text-gray-600">
                          Current Price
                        </div>
                        <div className="font-medium text-sm md:text-base">
                          {formatPrice(option.currentPrice)}{" "}
                          {tokenSymbol || "TOKENS"}
                        </div>
                      </div>
                    </div>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Step 2: Amount Input */}
        {sellingStep === "amount" && selectedOptionId !== null && (
          <div className="space-y-3 md:space-y-4">
            <div className="bg-red-50 border border-red-200 rounded-lg p-2 md:p-3">
              <div className="text-xs md:text-sm text-red-700">
                <div className="font-medium">
                  Selling: {market.options[selectedOptionId].name}
                </div>
                <div>Available: {formatShares(userSharesForOption)} shares</div>
                <div>
                  Current Price: {formatPrice(currentPrice)}{" "}
                  {tokenSymbol || "TOKENS"}
                </div>
              </div>
            </div>

            <div className="space-y-2">
              <label className="block text-xs md:text-sm font-medium text-gray-700">
                Shares to Sell
              </label>
              <div className="relative">
                <Input
                  ref={inputRef}
                  type="number"
                  placeholder="0.00"
                  value={sellAmount}
                  onChange={(e) => setSellAmount(e.target.value)}
                  className="pr-12 md:pr-16 text-sm md:text-base"
                  step="0.01"
                  min="0"
                  max={maxSellAmount.toString()}
                />
                <button
                  onClick={() => setSellAmount(maxSellAmount.toString())}
                  className="absolute right-1 md:right-2 top-1/2 -translate-y-1/2 text-xs bg-red-100 text-red-700 px-1 md:px-2 py-1 rounded hover:bg-red-200 transition-colors"
                >
                  MAX
                </button>
              </div>
              {estimatedRevenue && sellAmount && parseFloat(sellAmount) > 0 && (
                <div className="text-xs md:text-sm text-gray-600 mt-2 p-2 bg-gray-50 rounded">
                  <div className="flex justify-between">
                    <span>Shares to Sell:</span>
                    <span>{sellAmount}</span>
                  </div>
                  <div className="flex justify-between font-medium">
                    <span>Estimated Revenue:</span>
                    <span>
                      {estimatedRevenueFormatted.toFixed(4)}{" "}
                      {tokenSymbol || "TOKENS"}
                    </span>
                  </div>
                  <div className="flex justify-between text-xs text-gray-500">
                    <span>Avg Price/Share:</span>
                    <span>
                      {(
                        estimatedRevenueFormatted / parseFloat(sellAmount)
                      ).toFixed(4)}{" "}
                      {tokenSymbol || "TOKENS"}
                    </span>
                  </div>
                </div>
              )}
              {sellAmount && !estimatedRevenue && (
                <div className="text-xs md:text-sm text-gray-600">
                  Estimated Revenue: ~{estimatedRevenueFormatted.toFixed(4)}{" "}
                  {tokenSymbol || "TOKENS"}
                </div>
              )}
            </div>

            <div className="flex gap-2">
              <Button
                onClick={() => {
                  setSellingStep("initial");
                  setSellAmount("");
                }}
                variant="outline"
                className="flex-1 text-xs md:text-sm h-8 md:h-10"
              >
                Back
              </Button>
              <Button
                onClick={() => setSellingStep("confirm")}
                disabled={
                  !sellAmount ||
                  parseFloat(sellAmount) <= 0 ||
                  parseFloat(sellAmount) > maxSellAmount
                }
                className="flex-1 bg-red-600 hover:bg-red-700 text-xs md:text-sm h-8 md:h-10"
              >
                Review Sale
              </Button>
            </div>
          </div>
        )}

        {/* Step 3: Confirmation */}
        {sellingStep === "confirm" && selectedOptionId !== null && (
          <div className="space-y-3 md:space-y-4">
            <div className="bg-red-50 border border-red-200 rounded-lg p-3 md:p-4">
              <h3 className="font-medium text-red-800 mb-2 text-sm md:text-base">
                Confirm Sale
              </h3>
              <div className="space-y-1 md:space-y-2 text-xs md:text-sm text-red-700">
                <div className="flex justify-between">
                  <span>Option:</span>
                  <span className="font-medium">
                    {market.options[selectedOptionId].name}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span>Shares to Sell:</span>
                  <span className="font-medium">{sellAmount}</span>
                </div>
                <div className="flex justify-between">
                  <span>Current Price:</span>
                  <span className="font-medium">
                    {formatPrice(currentPrice)} {tokenSymbol}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span>Min Price ({SELL_SLIPPAGE_BPS / 100}% slippage):</span>
                  <span className="font-medium">
                    {formatPrice(
                      avgPricePerShareFromQuote > 0n
                        ? calculateMinPrice(avgPricePerShareFromQuote)
                        : calculateMinPrice(currentPrice)
                    )}{" "}
                    {tokenSymbol}
                  </span>
                </div>
                <hr className="border-red-200" />
                <div className="flex justify-between font-medium">
                  <span>Estimated Revenue:</span>
                  <span>
                    ~{estimatedRevenueFormatted.toFixed(4)} {tokenSymbol}
                  </span>
                </div>
              </div>
            </div>

            <div className="flex gap-2">
              <Button
                onClick={() => setSellingStep("amount")}
                variant="outline"
                className="flex-1 text-xs md:text-sm h-8 md:h-10"
              >
                Back
              </Button>
              <Button
                onClick={handleSell}
                disabled={isProcessing}
                className="flex-1 bg-red-600 hover:bg-red-700 text-xs md:text-sm h-8 md:h-10"
              >
                {isProcessing ? (
                  <>
                    <Loader2 className="mr-1 md:mr-2 h-3 w-3 md:h-4 md:w-4 animate-spin" />
                    Selling...
                  </>
                ) : (
                  "Confirm Sale"
                )}
              </Button>
            </div>
          </div>
        )}

        {/* Step 4: Processing */}
        {sellingStep === "processing" && (
          <div className="text-center py-3 md:py-4">
            <Loader2 className="mx-auto h-6 w-6 md:h-8 md:w-8 animate-spin text-red-600" />
            <p className="mt-2 text-xs md:text-sm text-gray-600">
              Processing your sale transaction...
            </p>
          </div>
        )}

        {/* Step 5: Success */}
        {sellingStep === "sellSuccess" && (
          <div className="text-center py-3 md:py-4">
            <div className="mx-auto w-10 h-10 md:w-12 md:h-12 bg-green-100 rounded-full flex items-center justify-center mb-2 md:mb-3">
              <svg
                className="w-5 h-5 md:w-6 md:h-6 text-green-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </div>
            <p className="text-green-700 font-medium text-sm md:text-base">
              Shares Sold Successfully!
            </p>
            <p className="text-xs md:text-sm text-gray-600 mt-1">
              Tokens have been transferred to your wallet.
            </p>
          </div>
        )}
      </div>
    </div>

);
}
