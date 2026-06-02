#!/usr/bin/env python

# cryptography
from cryptography.hazmat.primitives.asymmetric import ec
#from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes

from datetime import datetime, timezone, timedelta
import os, ipaddress

class CreateCACert():
    def __init__(
        self, 
        certFile                = "certificate.pem", 
        privateFile             = "private.key", 
        caCertFile              = "ca_cert.pem", 
        caprivateKeyFile        = "ca_private.key",
        caKey                   = None,                      # ※デフォルトNone→呼び出し側で生成する
        key                     = None,                      # ※デフォルトNone→呼び出し側で生成する
        overwrite               = False, 
        expire                  = 10,                        # 有効期限(年単位)
        host                    = "127.0.0.1",
        caHost                  = "BX293A_PEN",
        **kwargs
    ):
        # ※脆弱性ポイント回避: デフォルト引数でのec.generate_private_key()は
        #   クラス定義時に一度だけ評価されるため、Noneをデフォルトにしてここで生成する
        self.certFile           = certFile
        self.privateFile        = privateFile
        self.caCertFile         = caCertFile
        self.caprivateKeyFile   = caprivateKeyFile
        self.key                = key   if key   is not None else ec.generate_private_key(ec.SECP256R1())
        self.caKey              = caKey if caKey is not None else ec.generate_private_key(ec.SECP256R1())
        self.overwrite          = overwrite
        self.expire             = expire
        self.host               = host
        self.caHost             = caHost
        self.kwargs             = kwargs

        if(os.path.isfile(self.caCertFile)):
            try:
                with open(self.caCertFile, "rb") as f:
                    self.caCertKey = f.read()
            except:
                print("CA Certificate is None")
        else:
            self.create_ca_file()
        
        if(
            (self.privateFile is not None) and 
            (os.path.isfile(self.privateFile))
        ):
            try:
                with open(self.privateFile, "rb") as f: 
                    self.privateKey = f.read()
            except:
                print("Private Key is None")
        
        if(
            (not overwrite) and 
            (os.path.isfile(self.certFile))
        ):
            try:
                with open(self.certFile, "rb") as f: 
                    self.certificate = f.read()
            except:
                print("Certificate File Error")
        
        else:
            self.create_server_file()

    def create_server_file(self):
        subject = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COUNTRY_NAME, 
                    self.kwargs.get("country","JP")
                ),
                x509.NameAttribute(
                    NameOID.STATE_OR_PROVINCE_NAME, 
                    self.kwargs.get("prefecture","Aichi")
                ),
                x509.NameAttribute(
                    NameOID.LOCALITY_NAME, 
                    self.kwargs.get("city", "Nagoya")
                ),
                x509.NameAttribute(
                    NameOID.ORGANIZATION_NAME, 
                    self.kwargs.get("org", "University")
                ),
                x509.NameAttribute(
                    NameOID.COMMON_NAME, 
                    self.host
                ),
            ]
        )
        self.cert = x509.CertificateBuilder(
            subject_name        = subject,
            issuer_name         = x509.load_pem_x509_certificate(self.caCertKey).subject,
            serial_number       = x509.random_serial_number(),
            not_valid_before    = datetime.now(timezone.utc),
            not_valid_after     = datetime.now(timezone.utc) + timedelta(days=int(365 * self.expire)),
            public_key          = self.key.public_key(),
        )
        self.ip = x509.IPAddress(ipaddress.IPv4Address(self.host))
        self.cert = self.cert.add_extension(
            x509.SubjectAlternativeName(
                [self.ip]
            ),
            critical=False,
        )
        self.cert           = self.cert.sign(self.caKey, hashes.SHA256())

        self.certificate    = self.cert.public_bytes(serialization.Encoding.PEM)    # 証明書
        self.privateKey     = self.key.private_bytes(                               # 秘密鍵
            encoding        = serialization.Encoding.PEM,
            format          = serialization.PrivateFormat.PKCS8,
            encryption_algorithm = serialization.NoEncryption()
        )
        self.publicKey      = self.key.public_key().public_bytes(                   # 公開鍵
            encoding        = serialization.Encoding.PEM,
            format          = serialization.PublicFormat.SubjectPublicKeyInfo
        )
        with open(self.certFile, "wb") as f: 
            f.write(self.certificate)

        with open(self.privateFile, "wb") as f: 
            f.write(self.privateKey)


    def create_ca_file(self):
        subject = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COUNTRY_NAME, 
                    self.kwargs.get("country","JP")
                ),
                x509.NameAttribute(
                    NameOID.STATE_OR_PROVINCE_NAME, 
                    self.kwargs.get("prefecture","Aichi")
                ),
                x509.NameAttribute(
                    NameOID.LOCALITY_NAME, 
                    self.kwargs.get("city", "Nagoya")
                ),
                x509.NameAttribute(
                    NameOID.ORGANIZATION_NAME, 
                    self.kwargs.get("org", "University")
                ),
                x509.NameAttribute(
                    NameOID.COMMON_NAME, 
                    self.caHost
                ),
            ]
        )
        self.cacert = x509.CertificateBuilder(
            subject_name        = subject,
            issuer_name         = subject,
            serial_number       = x509.random_serial_number(),
            not_valid_before    = datetime.now(timezone.utc),
            not_valid_after     = datetime.now(timezone.utc) + timedelta(days=int(365 * self.expire)),
            public_key          = self.caKey.public_key(),
        )
        self.cacert             = self.cacert.add_extension(
            x509.BasicConstraints(
                ca              = True, 
                path_length     = None
            ), 
            critical            = True
        )
        self.cacert = self.cacert.add_extension(
            x509.KeyUsage(
                digital_signature   = True,
                content_commitment  = False,
                key_encipherment    = False,
                data_encipherment   = False,
                key_agreement       = False,
                key_cert_sign       = True,  # 証明書に署名する権限
                crl_sign            = True,       # CRLに署名する権限
                encipher_only       = False,
                decipher_only       = False,
            ), 
            critical                = True
        )

        self.cacert                 = self.cacert.sign(self.caKey, hashes.SHA256())

        self.caCertKey              = self.cacert.public_bytes(serialization.Encoding.PEM)

        self.caCertPrivateKey = self.caKey.private_bytes(
            encoding                = serialization.Encoding.PEM,
            format                  = serialization.PrivateFormat.PKCS8,
            encryption_algorithm    = serialization.NoEncryption()
        )

        with open(self.caCertFile, "wb") as f:
            f.write(self.caCertKey)

        with open(self.caprivateKeyFile, "wb") as f:
            f.write(self.caCertPrivateKey)

    def get_certificate(self):
        return self.certificate
    
    def get_private_key(self):
        return self.privateKey
    
    def get_ca_cert_key(self):
        return self.caCertKey


# ------------------------------------------------------------------ #
#  対話モード用ヘルパー
# ------------------------------------------------------------------ #

def _prompt(label: str, default: str) -> str:
    """入力プロンプト。空Enterでデフォルト値を返す。"""
    val = input(f"  {label} [{default}]: ").strip()
    return val if val else default


def _prompt_int(label: str, default: int, min_val: int = 1, max_val: int = 100) -> int:
    """整数入力。範囲外またはEnterでデフォルト値を返す。"""
    while True:
        raw = input(f"  {label} [{default}]: ").strip()
        if not raw:
            return default
        try:
            val = int(raw)
            if min_val <= val <= max_val:
                return val
            print(f"    ※ {min_val}〜{max_val} の範囲で入力してください")
        except ValueError:
            print("    ※ 数値を入力してください")


def _prompt_bool(label: str, default: bool) -> bool:
    """y/n 入力。"""
    default_str = "y" if default else "n"
    while True:
        raw = input(f"  {label} [{'y/N' if not default else 'Y/n'}]: ").strip().lower()
        if not raw:
            return default
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("    ※ y または n で入力してください")


def interactive_mode():
    """対話モード: 各パラメータをユーザーに確認しながら証明書を生成する。"""
    print("=" * 60)
    print("  自己証明書 対話生成モード")
    print("  ※ Enterでデフォルト値を使用します")
    print("=" * 60)

    # --- ファイル名 ---
    print("\n[出力ファイル名]")
    cert_file       = _prompt("サーバ証明書ファイル名",  "certificate.crt")
    private_file    = _prompt("サーバ秘密鍵ファイル名",  "private.key")
    ca_cert_file    = _prompt("CA証明書ファイル名",      "ca_cert.crt")
    ca_private_file = _prompt("CA秘密鍵ファイル名",      "ca_private.key")

    # --- 証明書の属性 ---
    print("\n[証明書の属性]")
    country    = _prompt("国コード (2文字)",        "JP")
    prefecture = _prompt("都道府県",                "Aichi")
    city       = _prompt("市区町村",                "Nagoya")
    org        = _prompt("組織名",                  "University")
    ca_host    = _prompt("CA の CommonName",        "BX293A_PEN")

    # --- サーバ ---
    print("\n[サーバ設定]")
    host    = _prompt("サーバIPアドレス (SAN含む)", "127.0.0.1")
    expire  = _prompt_int("有効期限 (年)",           10, min_val=1, max_val=99)

    # --- 上書き ---
    print("\n[その他]")
    overwrite = _prompt_bool("既存証明書を上書きする?", False)

    # --- 確認 ---
    print("\n" + "=" * 60)
    print("  以下の設定で生成します:")
    print(f"    サーバ証明書  : {cert_file}")
    print(f"    サーバ秘密鍵  : {private_file}")
    print(f"    CA証明書      : {ca_cert_file}")
    print(f"    CA秘密鍵      : {ca_private_file}")
    print(f"    国コード      : {country}")
    print(f"    都道府県      : {prefecture}")
    print(f"    市区町村      : {city}")
    print(f"    組織名        : {org}")
    print(f"    CA CommonName : {ca_host}")
    print(f"    サーバIP(SAN) : {host}")
    print(f"    有効期限      : {expire} 年")
    print(f"    上書き        : {'する' if overwrite else 'しない'}")
    print("=" * 60)

    if not _prompt_bool("実行しますか?", True):
        print("キャンセルしました。")
        return

    print("\n証明書を生成中...")
    CreateCACert(
        certFile         = cert_file,
        privateFile      = private_file,
        caCertFile       = ca_cert_file,
        caprivateKeyFile = ca_private_file,
        overwrite        = overwrite,
        expire           = expire,
        host             = host,
        caHost           = ca_host,
        country          = country,
        prefecture       = prefecture,
        city             = city,
        org              = org,
    )
    print("完了しました。")
    print(f"  {cert_file} / {private_file} / {ca_cert_file} / {ca_private_file}")


if __name__ == "__main__":
    import sys

    # 引数なし → 対話モード
    # --default  → 現在の設定(デフォルト値)で非対話実行
    if len(sys.argv) >= 2 and sys.argv[1] == "--default":
        print("デフォルト設定で証明書を生成します...")
        CreateCACert(
            certFile                = "certificate.crt", 
            privateFile             = "private.key", 
            caCertFile              = "ca_cert.crt", 
            caprivateKeyFile        = "ca_private.key",
        )
        print("完了しました。")
    else:
        interactive_mode()
