# Tetragon + Grafana + Star Wars Demo on CRC (macOS)

## Summary

**Who:** macOS users running CodeReady Containers (CRC) for OpenShift  
**What:** Deploy Tetragon with integrated Grafana, plus a Star Wars demo workload  
**How:** Using CRC, Helm, OpenShift CLI (`oc`), and provided automation scripts  

---

## 1. Clone the Demo Repository

```bash
git clone https://github.com/Trigas/tetragon-demo.git
cd tetragon-demo
```

---

## 2. Prepare Pull Secret

You need a valid Red Hat pull secret to run CRC.

- Download from: <https://cloud.redhat.com/openshift/install/crc/installer-provisioned>  
- Save as `pull-secret.txt` in this repo.  

⚠️ **Important:** If you are using the pull-secret file included in this repo, it is for demo purposes only and must **never** be shared outside your local lab. If you have your own pull secret from your Red Hat account, you may use it instead without this restriction.

---

## 3. Install CRC

You have two options:

**Option A: Download from Red Hat**  

- Visit: <https://www.redhat.com/en/blog/codeready-containers>  
- Download the latest macOS installer.  

![CRC Download from Red Hat](B9A77B28-6D90-4939-8DA0-C5E063F74D46.png)

**Option B: Install via Homebrew**  

```bash
brew install crc
```

---

## 4. Start CRC

```bash
crc setup
crc start --pull-secret-file pull-secret.txt
```

---

## 5. Deploy Tetragon + Grafana + Star Wars Demo

From the repo root (`~/tetragon-demo`):

```bash
./deploy-tetragon-with-grafana.sh
```

---

## 6. Example: Change Tracing Policy to Block Instead of Alerting

Edit your tracing policy YAML under `policies/`:

```yaml
actions:
  - type: Deny
    message: "Empire activity blocked"
```

Apply the policy:

```bash
oc apply -f policies/starwars_tetra_policy.yaml
```

---

## 7. References

- Red Hat CRC: <https://www.redhat.com/en/blog/codeready-containers>  
- Tetragon Docs: <https://isovalent.com/docs>
