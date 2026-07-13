NAME="ОбразыДляЗагрузки/ОСЧерноеМоре"

cp $NAME.img $NAME.img.старый

echo "Конвертирую img в VDI"

rm $NAME.vdi

VBoxManage convertfromraw $NAME.img $NAME.vdi

echo "Конвертирую img в QCOW2"

qemu-img convert -p -f raw -O qcow2 $NAME.img $NAME.qcow2
