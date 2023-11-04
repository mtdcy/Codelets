# SHELL脚本入门到精通

## POSIX SHELL

* no array
* no function keyword

## 重定向

### 从文件重定向 - `<`

```shell
#1.
sort < /path/to/file

#2. 
while read line; do
    echo $line
done < /path/to/file
```

### 从字符串定向 - `<<<` (non-POSIX)

```shell
#1. 
read a b <<< "Hello World"
```

### heredoc - `<<`

```shell
#1. 常用在脚本中输出整齐的文本
cat << EOF
Hello World!!!
EOF
```

??? `<<` vs `<<-`

### 管道 - `|`

```shell
#1. 常规
ip a | grep inet6
```

**`xargs`常和`|`一起使用，当后面的命令不接受管道，就可以使用`xargs`将其当做参数输入**

```shell
ls | echo       # nothing
ls | xargs echo # Good
```

## 字符串

### 默认值

```shell
#1. 如果var不存在，则返回DEFAULT
echo ${var-DEFAULT}
#2. 如果var不存在或为空，则返回DEFAULT
echo ${var:-DEFAULT}
#3. 如果var不存在，则`var=DEFAULT`并返回其值
echo ${var=DEFAULT}
#4. 如果var不存在或为空，则`var=DEFAULT`并返回其值
echo ${var:=DEFAULT}
```

### 截取

```shell
echo ${var:pos:length}
echo ${var:pos}
```

### 比较

```shell
#1. 完整匹配
[ "$a" = "$b" ]     [ "$a" != "$b" ]
[[ $a == $b ]]      [[ $a != $b ]]
#2. 通配符
[[ $a == a* ]]      [[ $a != a* ]]
#3. 部分匹配
[[ $a =~ ^[0-9]+ ]] 
#4. 字符串为空，长度不为0
[ -n "$a" ] # 为推荐
#5. 字符串为空，且长度为0
[ -z "$a" ] 
```

```shell
#1. match IPv4
regex="^([0-9]{1,3}\.){4}$"; [[ $addr. =~ $regex ]] && echo "ipv4"
#2. match MAC
regex="^([0-9a-fA-F]{2}:){6}$"; [[ $addr: =~ $regex ]] && echo "mac"
#3. match IPv6
regex="^([0-9a-fA-F]{0,4}:){8}$"; [[ $addr: =~ $regex ]] && echo "ipv6"
#4. match domain (also match with ipv4)
regex="^([0-9a-zA-Z]+\.)+$"; [[ $addr. =~ $regex ]] && echo "domain"
```

### 删除

```shell
#1. 最短匹配后缀
echo ${var%/*}
#2. 最长匹配后缀
echo ${var%%/*}
#3. 匹配前缀
# 将`%`替换为`#`
```

**Tips: `#`在`%`前面 => 所以`#`是匹配前缀**

### 替换

```shell
#1. 匹配第一个
echo ${var/match/replacement}
#2. 匹配所有
echo ${var//match/replacement}
#3. 匹配后缀
echo ${var/%match/replacement}
#4. 匹配前缀
echo ${var/#match/replacement}
```

### 大小写转换

```shell
${string,}  # => 首字母小写
${string,,} # => 全部小写
${string^}  # => 首字母大写
${string^^} # => 全部大写
```

**`^`在`,`上面**