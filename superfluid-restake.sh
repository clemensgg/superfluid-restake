#!/bin/zsh

set -e

printf "🤖 enter osmosisd keyring password: "
read -s password
echo ""

granter=$(echo $password | osmosisd keys show ledger --address)
echo "granter account is $granter"

grantee=$(echo $password | osmosisd keys show dev --address)
echo "grantee account is $grantee"

validator=$(echo $password | osmosisd keys show validator --bech val --address)
echo "validator account is $validator"

duration="1209600s" # 14 days in seconds

txflags="--gas auto --gas-adjustment 1.4 --gas-prices 0.0001uosmo --chain-id osmosis-1 --sign-mode amino-json --output json --node https://rpc.osmosis.zone:443"

grant() {
  types=(
    "/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward"
    "/osmosis.gamm.v1beta1.MsgJoinSwapShareAmountOut"
    "/osmosis.lockup.MsgLockTokens"
  )

  echo "🤖 composing tx..."
  osmosisd tx authz grant $grantee generic --msg-type ${types[0]} --from $granter --generate-only > tx.json
  for (( i=1; i<${#types[@]}; i++ )) {
    msgs=$(osmosisd tx authz grant $grantee generic --msg-type ${types[$i]} --from $granter --generate-only | jq -r '.body.messages')
    jq ".body.messages += $msgs" tx.json | sponge tx.json
  }

  echo "🤖 signing tx, plz confirm on ledger..."
  tx=$(echo $password | osmosisd tx sign tx.json --from $granter --ledger $txflags 2>&1)
  echo $tx > tx.json

  echo "🤖 broadcasting tx..."
  echo tx.json | jq
  echo $password | osmosisd tx broadcast tx.json $txflags

  rm tx.json
}

restake() {
  id=$1

  echo "🤖 querying grantee balance..."
  balance=$(osmosisd q bank balances $granter --output json | jq -r '.balances[] | select(.denom=="uosmo") | .amount')
  if [ -z $balance ]; then
    echo "error! uosmo balance is zero"
    return 1
  else
    echo "uosmo balance is $balance"
  fi

  echo "🤖 querying pool #$id..."
  pool=$(osmosisd q gamm pool 678 --output json | jq -r '.pool')
  amount=$(echo $pool | jq -r '.poolAssets[] | select(.token.denom=="uosmo") | .token.amount')
  totalShares=$(echo $pool | jq -r '.totalShares.amount')
  if [ -z amount ]; then
    echo "error! pool does not contain OSMO"
    return 1
  else
    echo "pool contains $amount uosmo and total shares $totalShares"
  fi

  echo "🤖 computing deposit amount..."
  deposit=$(( $balance * 99 / 100 )) # deposit 99% of the available balance
  shares=$(echo "$totalShares * $deposit / $amount / 2" | bc)
  echo "deposit max $deposit uosmo, expecting $shares shares"

  echo "🤖 composing tx..."
  osmosisd tx gamm join-swap-share-amount-out uosmo $balance $shares --pool-id $id --from $granter --generate-only > tx.json
  msgs=$(osmosisd tx lockup lock-tokens ${shares}gamm/pool/${id} --duration $duration --from $granter --generate-only | jq -r '.body.messages')
  jq ".body.messages += $msgs" tx.json | sponge tx.json

  echo "🤖 signing and broadcasting tx..."
  echo $password | osmosisd tx authz exec tx.json --from $grantee $txflags -y

  rm tx.json
}

# NOTE: ~90% chance this command will fail due to random errors related to ledger
grant

restake 678 # axlUSDC-OSMO pool
