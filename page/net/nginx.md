# nginx


## 强制跳转https

```
server {
    listen 80;
    server_name your.domain.com;
    return 301 https://$server_name$request_uri;
}
```

## location

`location [=|~|~*|^~|@] pattern { ... }`

### 完全匹配  `=`

```
location = /abcd {
    ...
}
```

* http://website.com/abcd 匹配
* http://website.com/ABCD 可能会匹配 ，也可以不匹配，取决于操作系统的文件系统是否大小写敏感（case-sensitive）。ps: Mac 默认是大小写不敏感的，git 使用会有大坑。
* http://website.com/abcd?param1&param2 匹配，忽略 querystring
* http://website.com/abcd/ 不匹配，带有结尾的/
* http://website.com/abcde 不匹配


### 大小写匹配 `~`

```
# 区分大小写
location ~ ^/abcd {
}

# 不区分大小写
location ~* ^abcd {
}
```

### 查找顺序及优先级

1. 精确匹配 =
2. 前缀匹配 ^~（立刻停止后续的正则搜索）
3. 按文件中顺序的正则匹配 ~或~*
4. 匹配不带任何修饰的前缀匹配。
