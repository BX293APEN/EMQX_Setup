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
        # self.host がIPアドレス(v4/v6)であればIPAddress、FQDNであればDNSName としてSANに追加する
        try:
            san_entry = x509.IPAddress(ipaddress.ip_address(self.host))
        except ValueError:
            san_entry = x509.DNSName(self.host)

        self.cert = self.cert.add_extension(
            x509.SubjectAlternativeName(
                [san_entry]
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


def formatted_prompt(
    message : str,
    default,
):
    if (type(default) is str):
        val = input(f"{message} [{default}]: ").strip()
        return val if val else default
    elif (type(default) is bool):
        default_str = "y" if default else "n"
        while True:
            raw = input(f"{message} [{default_str}] [y/n]:").strip().lower()
            if not raw:
                return default
            if raw in ("y", "yes"):
                return True
            if raw in ("n", "no"):
                return False
            print(f"[{raw}] is not [y/n]")
    elif (type(default) is int):
        while True:
            raw = input(f"{message} [{default}]: ").strip()
            if not raw:
                return default
            try:
                val = int(raw)
                return val
            except ValueError:
                print(f"[{raw}] is not [int]")
    



def interactive_mode():
    print("=" * 60)
    print(f"{' '*2}自己証明書 対話生成モード")
    print(f"{' '*2}Enterでデフォルト値を使用します")
    print("=" * 60)

    # --- ファイル名 ---
    print("\n[出力ファイル名]")
    cert_file           = formatted_prompt(f"{' '*2}サーバ証明書ファイル名",  "certificate.crt")
    private_file        = formatted_prompt(f"{' '*2}サーバ秘密鍵ファイル名",  "private.key")
    ca_cert_file        = formatted_prompt(f"{' '*2}CA証明書ファイル名",      "ca_cert.crt")
    ca_private_file     = formatted_prompt(f"{' '*2}CA秘密鍵ファイル名",      "ca_private.key")

    # --- 証明書の属性 ---
    print("\n[証明書の属性]")
    country             = formatted_prompt(f"{' '*2}国コード (2文字)",        "JP")
    prefecture          = formatted_prompt(f"{' '*2}都道府県",                "Aichi")
    city                = formatted_prompt(f"{' '*2}市区町村",                "Nagoya")
    org                 = formatted_prompt(f"{' '*2}組織名",                  "University")
    ca_host             = formatted_prompt(f"{' '*2}CA の CommonName",        "BX293A_PEN")

    # --- サーバ ---
    print("\n[サーバ設定]")
    host                = formatted_prompt(f"{' '*2}サーバIPアドレス (SAN含む)", "127.0.0.1")
    expire              = formatted_prompt(f"{' '*2}有効期限 (年)",           10,)

    # --- 上書き ---
    print("\n[その他]")
    overwrite           = formatted_prompt(f"{' '*2}既存証明書を上書きする?", False)

    # --- 確認 ---
    print("\n" + "=" * 60)
    print(f"{' '*2}以下の設定で生成します:")
    print(f"{' '*2}{' '*2}{'サーバ証明書':<20}: {cert_file}")
    print(f"{' '*2}{' '*2}{'サーバ秘密鍵':<20}: {private_file}")
    print(f"{' '*2}{' '*2}{'CA証明書':<20}: {ca_cert_file}")
    print(f"{' '*2}{' '*2}{'CA秘密鍵':<20}: {ca_private_file}")
    print(f"{' '*2}{' '*2}{'国コード':<20}: {country}")
    print(f"{' '*2}{' '*2}{'都道府県':<20}: {prefecture}")
    print(f"{' '*2}{' '*2}{'市区町村':<20}: {city}")
    print(f"{' '*2}{' '*2}{'組織名':<20}: {org}")
    print(f"{' '*2}{' '*2}{'CA CommonName':<20}: {ca_host}")
    print(f"{' '*2}{' '*2}{'サーバIP(SAN)':<20}: {host}")
    print(f"{' '*2}{' '*2}{'有効期限':<20}: {expire} 年")
    print(f"{' '*2}{' '*2}{'上書き':<20}: {'する' if overwrite else 'しない'}")
    print("=" * 60)

    if not formatted_prompt("実行しますか?", True):
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
    print(f"{cert_file} / {private_file} / {ca_cert_file} / {ca_private_file}")


if __name__ == "__main__":
    import sys
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
