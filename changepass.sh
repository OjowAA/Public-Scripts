#!/bin/bash

NEW_PASS='haemune2Ak'

USERS=(
AdmiralNelson
quartermaster
skulllord
dreadpirate
blackflag
SaltyDog23
PlunderMate56
RumRider12
GoldTooth89
HighTide74
SeaScourge30
ParrotJack67
CannonDeck45
BarnacleBill98
StormBringer09
CaptainHook88
RumRunner77
Quarterdeck99
HighSeas11
BarnacleBeard22
)

for user in "${USERS[@]}"; do
  if id "$user" &>/dev/null; then
    echo "${user}:${NEW_PASS}" | chpasswd
    echo "Password updated for $user"
  else
    echo "User $user does not exist — skipped"
  fi
done
