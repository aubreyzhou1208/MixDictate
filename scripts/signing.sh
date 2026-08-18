#!/usr/bin/env bash
# 建一个固定的签名身份，让权限不再每次重编译就失效。
#
#   ./scripts/signing.sh setup    建一个自签名的代码签名证书
#   ./scripts/signing.sh status   看现在有没有
#   ./scripts/signing.sh remove   删掉
#
# 为什么需要：默认走的是 ad-hoc 签名（`codesign --sign -`），它没有身份，
# macOS 只能拿二进制的哈希当身份用 —— 重编译一次哈希就变一个，TCC 里
# 麦克风和辅助功能的授权就全对不上了。系统设置里的开关还显示为开，
# 但已经不生效。
#
# 有了固定身份之后，TCC 认的是证书而不是哈希，重编译多少次都还是"同一个 App"。
#
# 这个证书只在你自己这台机器上有效，**不能用来分发给别人** —— 那需要
# Apple 的 Developer ID（付费账号），而且要走公证流程。

set -uo pipefail

IDENTITY="${MIXDICTATE_SIGN_IDENTITY:-MixDictate Dev}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"
}

case "${1:-status}" in
status)
    if has_identity; then
        echo "已有签名身份：$IDENTITY"
        security find-identity -v -p codesigning | grep "$IDENTITY"
        echo
        echo "下次 ./install.sh 会自动用它签名，权限不会再失效。"
    else
        echo "还没有固定签名身份，现在用的是 ad-hoc 签名。"
        echo "后果：每次重新编译，麦克风和辅助功能授权都会静默失效。"
        echo
        echo "建一个：./scripts/signing.sh setup"
    fi
    ;;

setup)
    if has_identity; then
        echo "已经有了：$IDENTITY"
        exit 0
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    echo "==> 生成自签名证书（10 年有效）"
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -subj "/CN=$IDENTITY" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>"$tmp/err"; then
        cat "$tmp/err" >&2
        echo "openssl 失败了。走图形界面那条路吧，见 README「固定签名身份」。" >&2
        exit 1
    fi

    openssl pkcs12 -export -out "$tmp/bundle.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass: >/dev/null 2>&1

    echo "==> 导入钥匙串"
    # -T /usr/bin/codesign：只授权 codesign 用这把私钥，不是对所有程序开放
    if ! security import "$tmp/bundle.p12" -k "$LOGIN_KEYCHAIN" -P "" \
        -T /usr/bin/codesign >/dev/null 2>&1; then
        echo "导入失败。走图形界面那条路吧，见 README「固定签名身份」。" >&2
        exit 1
    fi

    echo "==> 标记为可信（会弹一次系统认证）"
    # 不加信任的话 codesign 会说这个身份无效。写在用户域，不需要 sudo。
    security add-trusted-cert -r trustRoot -p codeSign \
        -k "$LOGIN_KEYCHAIN" "$tmp/cert.pem" 2>/dev/null \
        || echo "   （信任设置没成功，下面会告诉你还能不能用）"

    echo
    if has_identity; then
        echo "✅ 成功：$IDENTITY"
        echo
        echo "接下来："
        echo "  ./install.sh                      重新编译，这次用固定身份签名"
        echo "  ./scripts/permissions.sh reset    重新授权一次（最后一次）"
        echo
        echo "第一次编译时钥匙串可能弹窗要密码，选「始终允许」就不会再问。"
    else
        echo "❌ 证书建好了但 codesign 还认不出来，多半是信任设置没写进去。"
        echo "   试试手动授权：sudo security add-trusted-cert -d -r trustRoot \\"
        echo "     -p codeSign -k /Library/Keychains/System.keychain <证书>"
        echo "   或者走图形界面那条路，见 README「固定签名身份」。"
        exit 1
    fi
    ;;

remove)
    security delete-identity -c "$IDENTITY" "$LOGIN_KEYCHAIN" 2>/dev/null \
        && echo "已删除 $IDENTITY" \
        || echo "没找到 $IDENTITY"
    echo "以后会退回 ad-hoc 签名（权限每次重编译都会失效）。"
    ;;

*)
    echo "用法: $0 {setup|status|remove}" >&2
    exit 1
    ;;
esac
