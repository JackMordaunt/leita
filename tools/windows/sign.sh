#!/usr/bin/env bash
# Authenticode-signs the files given, with a timestamp, then has signtool
# verify each as Windows would. release.yml runs it in Git Bash on the Windows
# runner, once the plan step has chosen a route:
#
#   sign.sh store FILE...   signtool, with the certificate whose thumbprint
#                           WINDOWS_SIGN_CERT_THUMBPRINT holds, which must
#                           already be in the current user's personal store,
#                           where signtool looks by default
#   sign.sh akv FILE...     AzureSignTool (the executable AZURESIGNTOOL names),
#                           with the certificate in Azure Key Vault whose key
#                           lives in the vault's HSM; the key never leaves it
#                           and the runner holds nothing but a client secret:
#                             WINDOWS_SIGN_AKV_URL        https://<vault>.vault.azure.net
#                             WINDOWS_SIGN_AKV_CERT       the certificate's name in the vault
#                             WINDOWS_SIGN_AKV_TENANT     the Entra tenant id
#                             WINDOWS_SIGN_AKV_CLIENT_ID  the app registration allowed to sign
#                             WINDOWS_SIGN_AKV_CLIENT_SECRET its secret
#
# signtool is the Windows SDK's: the newest under Windows Kits is used, and the
# script stops, saying so, where there is none. A timestamp server that does not
# answer is not the end of a release: the next is tried.
set -euo pipefail
# Git Bash would rewrite signtool's /fd and /pa as paths.
export MSYS_NO_PATHCONV=1

route=${1:?usage: sign.sh store|akv FILE...}
shift
[ $# -gt 0 ] || { echo "sign.sh: no files to sign" >&2; exit 1; }

description=Leita
url=https://mordaunt.dev/leita
timestamps=(http://timestamp.digicert.com http://timestamp.sectigo.com)

signtool=$(find "/c/Program Files (x86)/Windows Kits/10/bin" -path '*/x64/signtool.exe' 2>/dev/null | sort -V | tail -n 1 || true)
[ -n "$signtool" ] || { echo "sign.sh: no signtool.exe in the Windows SDK on this runner" >&2; exit 1; }

signed=false
for ts in "${timestamps[@]}"; do
  case $route in
    store)
      : "${WINDOWS_SIGN_CERT_THUMBPRINT:?}"
      cmd=("$signtool" sign /sha1 "$WINDOWS_SIGN_CERT_THUMBPRINT" /fd sha256 /tr "$ts" /td sha256 /d "$description" /du "$url")
      ;;
    akv)
      : "${AZURESIGNTOOL:?}" "${WINDOWS_SIGN_AKV_URL:?}" "${WINDOWS_SIGN_AKV_CERT:?}" "${WINDOWS_SIGN_AKV_TENANT:?}" "${WINDOWS_SIGN_AKV_CLIENT_ID:?}" "${WINDOWS_SIGN_AKV_CLIENT_SECRET:?}"
      cmd=("$AZURESIGNTOOL" sign -kvu "$WINDOWS_SIGN_AKV_URL" -kvc "$WINDOWS_SIGN_AKV_CERT" -kvt "$WINDOWS_SIGN_AKV_TENANT"
        -kvi "$WINDOWS_SIGN_AKV_CLIENT_ID" -kvs "$WINDOWS_SIGN_AKV_CLIENT_SECRET"
        -fd sha256 -tr "$ts" -td sha256 -d "$description" -du "$url")
      ;;
    *)
      echo "sign.sh: the route is store or akv, not $route" >&2
      exit 1
      ;;
  esac
  files=()
  for f in "$@"; do files+=("$(cygpath -w "$f")"); done
  if "${cmd[@]}" "${files[@]}"; then signed=true; break; fi
  echo "::warning::signing with the timestamp server $ts failed; trying the next"
done
[ "$signed" = true ] || { echo "::error::no timestamp server let the files be signed"; exit 1; }

for f in "$@"; do
  "$signtool" verify /pa /v "$(cygpath -w "$f")"
done
