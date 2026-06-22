# sing-box-anytls

极简一键脚本sing-box内核anytls协议 by Herems 对接 mimo-v2.5-pro

#  用法
`bash sing-box-anytls.sh`                       # 全部使用默认值

`PORT=443 SNI=example.com bash setup-anytls.sh` # 自定义参数

# 我
`curl -LO https://github.com/crazypeace/sing-box-anytls/raw/main/install.sh || wget -O ${_##*/} $_ && PORT=2083 bash install.sh`
