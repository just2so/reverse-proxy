# 使用说明
## 注意：
* 必须申请了SSL了证书
* 必须有github令牌
* 浏览器无法访问文件内容，会返回403状态码
* 没有校验SSL证书和CA证书路径，若路径不对，可能会报错
```shell
bash <(curl -Ls https://raw.githubusercontent.com/co2f2e/config-nginx/main/nginx_auto_config.sh)
```
