#!/usr/bin/env python3
"""
Reale Sicherheits-/Filter-Messung der DNS-Provider ueber DNS-over-HTTPS (DoH).
DoH erreicht - anders als das im Container gehijackte UDP/53 - die ECHTEN
Resolver. Gemessene Merkmale sind Provider-Eigenschaften und damit
standortunabhaengig gueltig.
Nutzt curl --http2 (respektiert den HTTPS-Proxy der Umgebung, HTTP/2-faehig).
"""
import json, os, subprocess, tempfile, time
import dns.message, dns.rcode, dns.flags, dns.rdataclass

SC = "/tmp/claude-0/-home-user-Diretta-contact/216e7d02-a882-5731-82f6-a2b6d62030d3/scratchpad"
OUT = SC + "/security_real.json"

# (Name, IP(v4), Kategorie, DoH-URL)
PROVIDERS = [
    ("Cloudflare",             "1.1.1.1",        "Speed/Privacy",         "https://cloudflare-dns.com/dns-query"),
    ("Cloudflare Malware",     "1.1.1.2",        "Filter: Malware",       "https://security.cloudflare-dns.com/dns-query"),
    ("Cloudflare Family",      "1.1.1.3",        "Filter: Malware+Adult", "https://family.cloudflare-dns.com/dns-query"),
    ("Google",                 "8.8.8.8",        "Speed",                 "https://dns.google/dns-query"),
    ("Quad9 (secured)",        "9.9.9.9",        "Filter: Malware",       "https://dns.quad9.net/dns-query"),
    ("Quad9 Unsecured",        "9.9.9.10",       "Kein Filter",           "https://dns10.quad9.net/dns-query"),
    ("OpenDNS Home",           "208.67.222.222", "Filter: Security",      "https://doh.opendns.com/dns-query"),
    ("OpenDNS FamilyShield",   "208.67.222.123", "Filter: Adult+Sec",     "https://doh.familyshield.opendns.com/dns-query"),
    ("AdGuard",                "94.140.14.14",   "Filter: Ads+Tracker",   "https://dns.adguard-dns.com/dns-query"),
    ("AdGuard Family",         "94.140.14.15",   "Filter: Ads+Adult",     "https://family.adguard-dns.com/dns-query"),
    ("AdGuard Unfiltered",     "94.140.14.140",  "Kein Filter",           "https://unfiltered.adguard-dns.com/dns-query"),
    ("CleanBrowsing Security", "185.228.168.9",  "Filter: Security",      "https://doh.cleanbrowsing.org/doh/security-filter/"),
    ("CleanBrowsing Family",   "185.228.168.168","Filter: Adult+Sec",     "https://doh.cleanbrowsing.org/doh/family-filter/"),
    ("Mullvad",                "194.242.2.2",    "Privacy",               "https://dns.mullvad.net/dns-query"),
    ("Mullvad AdBlock",        "194.242.2.3",    "Privacy+Ads",           "https://adblock.dns.mullvad.net/dns-query"),
]

# Bekannte Block-Sentinel-IPs (Provider-Sperrseiten / Null-Routes)
BLOCK_SENTINELS = {"0.0.0.0", "::", "127.0.0.1", "::1"}
BLOCK_PREFIXES  = ("146.112.61.", "146.112.62.",     # OpenDNS Block-Page
                   "94.140.14.35", "94.140.14.36",   # AdGuard Block-IPs
                   "94.140.14.33", "94.140.14.34")

# Testdomains je Kategorie
DOM_ADS    = ["doubleclick.net", "www.googleadservices.com", "ads.pubmatic.com"]
DOM_ADULT  = ["pornhub.com", "xvideos.com"]
DOM_MALW   = ["internetbadguys.com",          # offizielle OpenDNS-Phishing-Testdomain
              "examplemalwaredomain.com",      # SWITCH/Testdomain fuer Malware-Filter
              "examplephishingdomain.com"]     # Testdomain fuer Phishing-Filter
DOM_CTRL   = ["example.com", "google.com"]     # muessen immer aufloesen

def wire(qname, rdtype="A", want_dnssec=False):
    return dns.message.make_query(qname, rdtype, want_dnssec=want_dnssec).to_wire()

def doh_query(url, qname, rdtype="A", want_dnssec=False, timeout=10):
    """DoH-POST via curl --http2. Gibt dns.message oder None."""
    qf = tempfile.NamedTemporaryFile(delete=False, dir=SC, suffix=".q")
    rf = qf.name + ".r"
    try:
        qf.write(wire(qname, rdtype, want_dnssec)); qf.close()
        code = subprocess.run(
            ["curl","-s","--http2","--max-time",str(timeout),
             "-H","accept: application/dns-message",
             "-H","content-type: application/dns-message",
             "--data-binary","@"+qf.name, url, "-o", rf,
             "-w","%{http_code}"],
            capture_output=True, text=True).stdout.strip()
        if code != "200" or not os.path.exists(rf) or os.path.getsize(rf) == 0:
            return None, code
        with open(rf,"rb") as f:
            return dns.message.from_wire(f.read()), code
    except Exception as e:
        return None, f"ERR:{type(e).__name__}"
    finally:
        for p in (qf.name, rf):
            try: os.unlink(p)
            except: pass

def a_ips(resp):
    out=[]
    if resp is None: return out
    for rr in resp.answer:
        for it in rr:
            if it.rdtype in (1,28):  # A / AAAA
                out.append(it.address)
    return out

def is_blocked(resp, code):
    if resp is None:
        return None if code not in ("200",) else False
    rc = resp.rcode()
    if rc in (dns.rcode.NXDOMAIN, dns.rcode.REFUSED):
        return True
    ips = a_ips(resp)
    if rc == dns.rcode.NOERROR and not ips:
        # NODATA fuer A -> ggf. geblockt; pruefe ob ueberhaupt Antwortsektion leer
        return True
    for ip in ips:
        if ip in BLOCK_SENTINELS or any(ip.startswith(p) for p in BLOCK_PREFIXES):
            return True
    return False

def cat_status(url, domains):
    """blocked/partial/allowed/na ueber mehrere Domains einer Kategorie."""
    res=[]
    for d in domains:
        resp, code = doh_query(url, d)
        res.append(is_blocked(resp, code))
    valid=[r for r in res if r is not None]
    if not valid: return "na", res
    if all(valid): return "blocked", res
    if any(valid): return "partial", res
    return "allowed", res

def run():
    print("== Reale Sicherheitsmessung via DoH (curl --http2) ==", flush=True)
    matrix={}
    for name, ip, cat, url in PROVIDERS:
        e={"ip":ip,"category":cat,"doh_url":url}

        # DoH erreichbar?
        resp,code = doh_query(url,"example.com")
        e["doh_reachable"] = (resp is not None)
        e["doh_http_code"] = code

        # DNSSEC-Validierung: dnssec-failed.org -> SERVFAIL = validiert
        resp,code = doh_query(url,"dnssec-failed.org")
        if resp is not None:
            e["dnssec_validates"] = (resp.rcode()==dns.rcode.SERVFAIL)
            e["dnssec_rcode"]=dns.rcode.to_text(resp.rcode())
        else:
            e["dnssec_validates"]=None; e["dnssec_rcode"]="(DoH n/a)"

        # AD-Flag auf korrekt signierter Domain
        resp,code = doh_query(url,"internetsociety.org","A",want_dnssec=True)
        e["ad_flag"]= bool(resp.flags & dns.flags.AD) if resp is not None else None

        # NXDOMAIN-Handling (kein Hijack erwuenscht)
        resp,code = doh_query(url,"nx-diretta-test-7k3p9q2.com")
        if resp is not None:
            ips=a_ips(resp)
            e["nxdomain_ok"] = (resp.rcode()==dns.rcode.NXDOMAIN) or (not ips)
        else:
            e["nxdomain_ok"]=None

        # Filterkategorien
        e["ads"],    e["_ads_raw"]    = cat_status(url, DOM_ADS)
        e["adult"],  e["_adult_raw"]  = cat_status(url, DOM_ADULT)
        e["malware"],e["_malware_raw"]= cat_status(url, DOM_MALW)

        # Kontrolle: harmlose Domains muessen aufloesen
        ctrl=[]
        for d in DOM_CTRL:
            resp,code=doh_query(url,d)
            ctrl.append(bool(a_ips(resp)))
        e["control_resolves"]= all(ctrl)

        matrix[name]=e
        print(f"  {name:24} DoH={e['doh_reachable']!s:5} DNSSEC={e['dnssec_validates']!s:5} "
              f"Ads={e['ads']:7} Adult={e['adult']:7} Malware={e['malware']:7} NXok={e['nxdomain_ok']}", flush=True)
    return matrix

if __name__=="__main__":
    t0=time.time()
    m=run()
    json.dump({"vantage":"DoH from GCP Columbus/Ohio -> reale Provider (standortunabhaengige Merkmale)",
               "providers":m,"duration_s":round(time.time()-t0,1)},
              open(OUT,"w"), indent=2)
    print("\nGESCHRIEBEN:",OUT," Dauer %.1fs"%(time.time()-t0))
