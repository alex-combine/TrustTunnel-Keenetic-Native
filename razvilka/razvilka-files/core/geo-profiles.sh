# geo-profiles.sh — country profiles for geo-build.sh.
# A profile says what to subtract from the country map (what goes via VPN although the address is inside the country):
#   SUBTRACT_DC=1  — subtract the world data center list (clouds, hosting: other people's VPNs and sites live there)
#   KEEP_ASN="…"   — BUT keep these companies direct even if they are in the data center list
#                    (their clouds are the main services of the country: in China Taobao lives in the Alibaba cloud)
#   EXTRA_ASN="…"  — additionally subtract local hosting providers missing from the world list
#   COUNTRY_NAME, FLAG — for Razvilka texts
# Any value can be overridden in /opt/etc/direct-routes.geo.conf.
# Countries missing from the list use the general rule: country minus world data centers.
profile() {
  SUBTRACT_DC=1; KEEP_ASN=""; EXTRA_ASN=""; FLAG=""; DNS_SPLIT=0   # DNS_SPLIT=1 — split DNS (geo-dns.sh)
  case "$1" in
    ru) COUNTRY_NAME="Россия"; FLAG="🇷🇺"
        # Yandex.Cloud, Selectel ×2, Timeweb, Reg.ru, DDoS-Guard, Qrator, ServicePipe, Beget, FirstVDS, Aeza, VDSina ×2
        EXTRA_ASN="200350 49505 50340 9123 197695 57724 200449 201706 198610 29182 210644 48282 62217";;
    by) COUNTRY_NAME="Беларусь"; FLAG="🇧🇾";;
    kz) COUNTRY_NAME="Казахстан"; FLAG="🇰🇿";;
    uz) COUNTRY_NAME="Узбекистан"; FLAG="🇺🇿";;
    cn) COUNTRY_NAME="Китай"; FLAG="🇨🇳"; DNS_SPLIT=1
        # Alibaba (Taobao, Alipay, Aliyun) 37963 45102 24429 · Tencent (QQ, WeChat) 45090 132203 ·
        # Huawei Cloud 55990 136907 · Baidu 38365 55967 · ByteDance 138699 396986 · Kingsoft Cloud 59019
        KEEP_ASN="37963 45102 24429 45090 132203 55990 136907 38365 55967 138699 396986 59019";;
    ir) COUNTRY_NAME="Иран"; FLAG="🇮🇷";;
    tr) COUNTRY_NAME="Турция"; FLAG="🇹🇷";;
    ae) COUNTRY_NAME="ОАЭ"; FLAG="🇦🇪";;
    *)  COUNTRY_NAME=$(echo "$1" | tr a-z A-Z);;
  esac
}
