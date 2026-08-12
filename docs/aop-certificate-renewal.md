# Zone-level AOP certificate renewal

This runbook renews the **client certificate that Cloudflare presents to
HAProxy**. It is not the Cloudflare Origin CA server certificate that HAProxy
presents to Cloudflare.

No CDK deployment or HAProxy upgrade is required for a normal renewal. Start
when Cloudflare sends the 30-day expiry notification; do not wait for the
14-day notification.

## Certificate inventory

Record these values when creating or renewing the certificate. Keep private-key
locations in a password manager or secrets inventory, not in this repository.

| Item | Value |
|---|---|
| Cloudflare zone | `aoctech.app` |
| Cloudflare certificate ID | `<record after upload>` |
| AOP leaf expiry | `<record after upload>` |
| Root CA expiry | `<openssl x509 -in rootca.crt -noout -enddate>` |
| Encrypted offline root key | `<secure backup location>` |
| Cloudflare AOP enabled | `<verified date>` |

The files have different roles:

| File | Where it belongs |
|---|---|
| `cert.crt` | Upload to Cloudflare as the AOP client certificate |
| `cert.key` | Upload to Cloudflare; keep only an encrypted offline backup |
| `rootca.crt` | HAProxy trust store through the per-environment SSM parameter |
| `rootca.key` | Encrypted offline only; never upload to Cloudflare or AWS |

## Preferred renewal: reuse the existing CA

Use this procedure while the existing `rootca.crt` and encrypted `rootca.key`
are available and the CA remains valid for longer than the new leaf. The
original setup gives the root roughly five years and a leaf roughly two years,
so this should be the usual renewal path.

### 1. Check the CA before signing

Work on a trusted machine. The following check succeeds with exit code zero
only if the CA remains valid for at least 760 days:

```bash
umask 077
openssl x509 -in /secure/path/rootca.crt -noout -subject -serial -dates
openssl x509 -in /secure/path/rootca.crt -checkend 65664000 -noout
```

If the second command fails, follow **Rotate the private CA** below instead of
issuing another 730-day leaf.

### 2. Create and validate a new leaf certificate

Use a new key. Do not reuse the expiring leaf's private key.

```bash
RENEWAL_DIR=aop-renewal-YYYY-MM-DD
mkdir --mode=700 "$RENEWAL_DIR"
cd "$RENEWAL_DIR"

openssl req -new -nodes -newkey rsa:4096 \
  -keyout cert.key -out cert.csr \
  -subj "/O=AOCTech/CN=aoctech.app"
printf '%s\n' 'basicConstraints=CA:FALSE' > cert.v3.ext
openssl x509 -req -in cert.csr \
  -CA /secure/path/rootca.crt -CAkey /secure/path/rootca.key \
  -CAcreateserial -out cert.crt -days 730 -sha256 \
  -extfile cert.v3.ext

openssl verify -CAfile /secure/path/rootca.crt cert.crt
openssl x509 -in cert.crt -noout -subject -issuer -serial -dates
```

The `openssl verify` result must be `cert.crt: OK`. Confirm that the issuer is
the expected AOCTech root and that the expiry is roughly two years away.

Check that `cert.crt` and `cert.key` are a pair. These two commands must print
the same SHA-256 value:

```bash
openssl x509 -in cert.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl sha256
openssl pkey -in cert.key -pubout -outform DER | openssl sha256
```

### 3. Upload the replacement to Cloudflare

In the `aoctech.app` zone, open **SSL/TLS -> Origin Server -> Authenticated
Origin Pulls -> Zone-level -> Upload certificate**. Paste `cert.crt` as the
certificate and `cert.key` as its private key. Upload the leaf—not
`rootca.crt`—and save the new certificate ID and expiry in the inventory above.

Wait until the new certificate reports `active`. Keep zone-level Authenticated
Origin Pulls enabled. Do not delete the previous certificate or its encrypted
backup yet.

Because the new leaf is signed by the existing trusted CA, do **not** change
`/ctech/{environment}/lbalancer/tls/aop-ca` during this normal renewal.

### 4. Verify traffic and retain rollback material

Test every deployed environment and at least one hostname for every origin path:

```bash
curl --fail --show-error --silent --output /dev/null \
  --write-out 'accounts-api: %{http_code}\n' \
  https://accounts-api.aoctech.app/v1.0/health-check
curl --fail --show-error --silent --output /dev/null \
  --write-out 'wallet-api: %{http_code}\n' \
  https://wallet-api.aoctech.app/v1.0/health-check
curl --fail --show-error --silent --output /dev/null \
  --write-out 'poker-api: %{http_code}\n' \
  https://poker-api.aoctech.app/v1.0/health-check
curl --fail --show-error --silent --output /dev/null \
  --write-out 'dfe-api: %{http_code}\n' \
  https://dfe-api.aoctech.app/v1.0/health-check
```

Repeat with `*-dev.aoctech.app` and `*-stage.aoctech.app` if those environments
are deployed. An application-specific healthy response such as 207 is also
valid where the route declares it.

Then inspect the load balancer through SSM:

```bash
sudo systemctl status haproxy ctech-lbalancer-reconcile.timer
sudo journalctl -u haproxy -u ctech-lbalancer-reconcile.service \
  --since '30 minutes ago' --no-pager
sudo /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
```

Keep the previous leaf certificate and key in encrypted offline storage for at
least 24 hours. If the replacement fails, upload the previous pair again in the
same Cloudflare zone-level panel. Once the new certificate has worked for 24
hours, retire the previous certificate in Cloudflare and update the inventory.

## Rotate the private CA

Rotate the CA only if `rootca.key` is unavailable, the root is near expiry, or
the root key may be compromised. This is a zone-wide change: Cloudflare will use
the new client certificate for every proxied `aoctech.app` origin. Prepare
`prod`, `stage`, and `dev` before switching Cloudflare if they are deployed.

1. On a trusted machine, generate a new encrypted root CA and a new leaf/key
   pair. Use new filenames so the old material cannot be overwritten
   accidentally:

   ```bash
   umask 077
   openssl genrsa -aes256 -out new-rootca.key 4096
   openssl req -x509 -new -key new-rootca.key -sha256 -days 1826 \
     -out new-rootca.crt -subj "/O=AOCTech/CN=aoctech.app"
   openssl req -new -nodes -newkey rsa:4096 \
     -keyout new-cert.key -out new-cert.csr \
     -subj "/O=AOCTech/CN=aoctech.app"
   printf '%s\n' 'basicConstraints=CA:FALSE' > new-cert.v3.ext
   openssl x509 -req -in new-cert.csr \
     -CA new-rootca.crt -CAkey new-rootca.key -CAcreateserial \
     -out new-cert.crt -days 730 -sha256 -extfile new-cert.v3.ext

   openssl verify -CAfile new-rootca.crt new-cert.crt
   openssl x509 -in new-rootca.crt -noout -subject -serial -dates
   openssl x509 -in new-cert.crt -noout -subject -issuer -serial -dates
   ```

   The root key must remain encrypted and offline. The leaf key is necessarily
   unencrypted for Cloudflare's upload, so protect the working directory and
   archive or dispose of it according to the secrets-retention policy after the
   observation window.
2. Create a temporary CA bundle containing the old root followed by the new
   root. HAProxy accepts all CA certificates in this PEM bundle:

   ```bash
   cp /secure/path/old-rootca.crt aop-ca-transition.pem
   printf '\n' >> aop-ca-transition.pem
   cat new-rootca.crt >> aop-ca-transition.pem
   openssl crl2pkcs7 -nocrl -certfile aop-ca-transition.pem \
     | openssl pkcs7 -print_certs -noout
   wc -c aop-ca-transition.pem
   ```

   Confirm that both CA subjects appear and that the bundle is no larger than
   the 4,096-byte SSM Standard Parameter limit. If two RSA roots exceed the
   limit, add `--tier Advanced` to the upload command below; an Advanced
   Parameter is safer than a one-CA cutover. It cannot be downgraded in place:
   after the rotation, use a controlled delete, wait at least 30 seconds, and
   recreate the new-root-only value with `--tier Standard`. HAProxy retains its
   locally installed trust file while the parameter is briefly absent. Perform
   this cost cleanup one environment at a time and revalidate each one.
3. Upload the transition bundle to every deployed load-balancer environment:

   ```bash
   for ENVIRONMENT in prod stage dev; do
     aws ssm put-parameter --type SecureString \
       --name "/ctech/${ENVIRONMENT}/lbalancer/tls/aop-ca" \
       --value "$(<aop-ca-transition.pem)" --overwrite \
       --profile ctech --region us-east-1
   done
   ```

   Omit environments that do not exist. The reconciler checks SSM every 30
   seconds and reloads HAProxy when the trust bundle changes.
4. On each load balancer, wait for the reconciliation, validate the HAProxy
   configuration, and confirm both CA subjects are installed:

   ```bash
   sudo systemctl status haproxy ctech-lbalancer-reconcile.timer
   sudo journalctl -u ctech-lbalancer-reconcile.service -n 50 --no-pager
   sudo /usr/local/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
   sudo openssl crl2pkcs7 -nocrl -certfile /etc/haproxy/tls/aop-ca.pem \
     | sudo openssl pkcs7 -print_certs -noout
   ```
5. Only after every origin trusts both roots, upload the new leaf certificate
   and key to Cloudflare and wait for `active`. Run all verification checks from
   the preferred renewal procedure.
6. Keep both roots trusted for at least 24 hours. Rollback during this window is
   simply re-uploading the previous Cloudflare leaf/key pair.
7. After the observation period, replace each SSM transition bundle with only
   `new-rootca.crt`, confirm reconciliation, and then retire the old Cloudflare
   certificate. Archive the old CA material according to the secrets-retention
   policy; never leave CA private keys on the load balancer.

## Alerts and emergency behavior

Configure Cloudflare's **Zone-level Authenticated Origin Pulls Certificate
Expiration Alert**. Cloudflare sends notifications 30 and 14 days before
expiry.

If the AOP leaf expires before renewal, Cloudflare-to-origin TLS will fail and
clients will see Cloudflare 52x errors. Do not disable HAProxy client-certificate
verification as the normal fix. Issue and upload a new leaf signed by the
currently trusted CA. Disabling AOP is an emergency availability trade-off and
must be paired with an explicit, time-limited security decision.

## Separate Origin CA server-certificate renewal

The Origin CA server certificate is independent. When that certificate nears
expiry, create a new ECC PEM Origin Certificate covering `aoctech.app` and
`*.aoctech.app`, then update these two SSM parameters for each environment:

```text
/ctech/{environment}/lbalancer/tls/origin-certificate
/ctech/{environment}/lbalancer/tls/origin-private-key
```

The reconciler validates the pair and gracefully reloads HAProxy. Test through
Cloudflare in **Full (strict)** mode before retiring the previous server
certificate and key. This operation does not change the AOP client certificate
or `/ctech/{environment}/lbalancer/tls/aop-ca`.

## References

- [Cloudflare zone-level Authenticated Origin Pull setup](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/zone-level/)
- [Cloudflare Origin TLS Client Auth API](https://developers.cloudflare.com/api/resources/origin_tls_client_auth/)
- [AWS Systems Manager Parameter Store tiers](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html)
- [AWS `DeleteParameter` wait requirement](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_DeleteParameter.html)
