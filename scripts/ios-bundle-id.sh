#!/bin/bash
# Shared iOS identity policy. Sourcing this file performs no device/account operations.
IMIC_RELEASE_TEAM=5H39F98ND4
IMIC_RELEASE_BUNDLE_ID=art.malette.imic.app
IMIC_DEV_BUNDLE_ID=art.malette.imic.dev
IMIC_SIM_BUNDLE_ID=${IMIC_RELEASE_BUNDLE_ID}

imic_device_identity() {
  TEAM=${IMIC_DEV_TEAM:-$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -nE 's/.*teamID = ([A-Z0-9]+).*/\1/p' | head -1 || true)}
  if [[ ! "${TEAM}" =~ ^[A-Z0-9]{10}$ ]]; then
    echo '没有有效的签名团队；请用 IMIC_DEV_TEAM 指定已有团队。 / Set IMIC_DEV_TEAM to an existing signing team.' >&2
    return 1
  fi
  BUNDLE_ID=${IMIC_BUNDLE_ID:-${IMIC_DEV_BUNDLE_ID}}
  case "${BUNDLE_ID}" in
    "${IMIC_RELEASE_BUNDLE_ID}"|"${IMIC_RELEASE_BUNDLE_ID}.uitests")
      if [ "${TEAM}" != "${IMIC_RELEASE_TEAM}" ]; then
        echo "拒绝签名：团队 ${TEAM} 不能使用发布 Bundle ID ${BUNDLE_ID}（包括 .uitests 运行器）；自动签名会在个人/其他团队占用发布 ID。请使用 ${IMIC_DEV_BUNDLE_ID}。 / Refusing signing: automatic signing would reserve the release ID in the wrong team; use ${IMIC_DEV_BUNDLE_ID}." >&2
        return 1
      fi
      [ "$BUNDLE_ID" = "$IMIC_RELEASE_BUNDLE_ID" ] || {
        echo '测试运行器 ID 由 App ID 自动派生，不能作为 App ID。 / The test runner ID is derived from the app ID.' >&2
        return 1
      } ;;
    "${IMIC_DEV_BUNDLE_ID}") ;;
    *) echo "不支持的本地 Bundle ID：${BUNDLE_ID}；只允许 ${IMIC_DEV_BUNDLE_ID} 或 ${IMIC_RELEASE_BUNDLE_ID}。 / Unsupported local bundle ID." >&2; return 1 ;;
  esac
  export IMIC_DEV_TEAM="${TEAM}" IMIC_BUNDLE_ID="${BUNDLE_ID}"
}

imic_print_device_identity() {
  printf 'Team: %s\nIMIC_BUNDLE_ID: %s\nUI tests: %s.uitests\n' "${TEAM}" "${BUNDLE_ID}" "${BUNDLE_ID}"
}

imic_require_release_team() {
  if [ "$1" != "${IMIC_RELEASE_TEAM}" ]; then
    echo "拒绝发布签名：发布 ID 只能在团队 ${IMIC_RELEASE_TEAM} 中使用。 / Release signing requires team ${IMIC_RELEASE_TEAM}." >&2
    return 1
  fi
}
