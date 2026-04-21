# Generate a manifest

1. To generate a manifest from an existing instance, run:

```shell
dnf repoquery --installed --qf '%{name}'
```
