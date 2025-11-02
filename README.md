# 🛡️ HAProxy and Let's Encrypt Add-on for Home Assistant

**HAProxy** is a high-performance, reliable **reverse-proxy** used for load balancing and proxying TCP/HTTP applications. It is frequently employed in high-traffic environments due to its stable, high-performance architecture. By placing HAProxy in front of Home Assistant, you create a robust **security and distribution layer**.

It efficiently handles the computationally intensive process of encrypting and decrypting web traffic (**SSL termination**), thereby conserving the processing power of the core Home Assistant (HA) instance for smart home tasks. This strategy not only improves security but also enhances the perceived performance of your Home Assistant UI.

This Home Assistant Add-on bundles HAProxy with **Certbot** (the official Let's Encrypt client) to provide high-performance SSL termination. This seamless integration allows you to **securely encrypt all traffic** to your Home Assistant instance and any other exposed services, with the entire certificate lifecycle—from initial request to automated renewal—managed entirely within the Supervisor environment.

---

## 🔒 How HTTPS Works

**HTTPS** relies on the **Transport Layer Security (TLS)** protocol. The **TLS Handshake** establishes a secure connection:

1.  The client connects to the server (**HAProxy**), which presents its **SSL certificate**, signed by a trusted **Certificate Authority (CA)**. The client's operating system or browser maintains a comprehensive list of globally trusted CAs. If the signature on the presented certificate matches a trusted root, the client confirms the certificate's validity and the server's legitimate identity.
2.  The client verifies the CA's signature and uses the certificate's publicly available **public key** to securely encrypt a unique **symmetric session key**.
3.  Only the server, holding the corresponding and highly secret **private key**, can decrypt this initial **asymmetric exchange** to obtain the shared session key. This initial phase uses slower, asymmetric encryption solely to safely transmit the key.
4.  All subsequent traffic is rapidly encrypted and decrypted using this shared **symmetric session key**, guaranteeing both high speed, data integrity, and confidentiality throughout the entire connection duration.

**Let's Encrypt** provides these essential certificates **for free**, making secure website access widely accessible and encouraging ubiquitous encryption for all self-hosted applications.

---

## 🛠️ Home Assistant Add-on Installation

This is a Supervisor add-on, eliminating the need for complex, manual Docker configuration.

1.  **Add the Repository:** Go to the Add-on Store, select "Repositories," and add: `https://github.com/lemariva/haproxy-certbot-hassio-addon`.
2.  **Install:** Find "**HaProxy-Certbot**" and click "**Install**."

---

## ⚙️ Configuration

The add-on manages certificate requests and renewals automatically based on these settings:

| Option | Type | Description |
| :--- | :--- | :--- |
| **ha\_ip\_address** | `string` | **MANDATORY**. Internal IP of your Home Assistant instance (e.g., `192.168.1.10`) for traffic forwarding. |
| **ha\_port** | `integer` | HA listening port (default: `8123`). |
| **cert\_domain** | `string` | **MANDATORY**. Domain name to secure (e.g., `myhome.duckdns.org`). Must resolve to your public IP. |
| **cert\_email** | `string` | **MANDATORY**. Email for Let's Encrypt notifications, expiration warnings, and recovery purposes. |
| **force\_redirect** | `boolean` | If **true** (default), all insecure HTTP traffic received on port **80** is automatically redirected via a **301 Permanent Redirect** to the secure HTTPS port **443**. |
| **stats\_user/stats\_password** | `string` | Credentials required for accessing the HAProxy real-time statistics panel on port **9999**. |
| **log\_level** | `enum` | Sets the HAProxy verbosity level (e.g., `info`, `warning`, `debug`). This controls the detail shown in the add-on logs. Default is `info`. |
| **data\_path** | `string` | Internal storage path for configs and certificates. |

---

## ➡️ Step 1. Configure Home Assistant (Trusted Proxies)

When HAProxy forwards an external request internally to Home Assistant, it inserts the client's original IP address into the **`X-Forwarded-For`** header. Home Assistant must explicitly **trust the add-on's source IP** to process this header and prevent a "**400 Bad Request**" error. If Home Assistant does not explicitly trust the proxy, it sees an internal Docker IP as the origin and rejects the request as a potential spoofing attempt, resulting in the security rejection.

Since the add-on's internal Docker IP is dynamically assigned and can change upon host or add-on restarts, the most stable approach is to trust the entire Supervisor add-on subnet:

Add the following to your Home Assistant's main `configuration.yaml`:

```yaml
# configuration.yaml

http:
  use_x_forwarded_for: true
  trusted_proxies:
    # Trusts all possible internal Add-on IPs used by the Supervisor (172.30.32.0/24 is the standard Docker network).
    - 172.30.32.0/24