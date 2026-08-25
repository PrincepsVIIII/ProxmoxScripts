

# Stop and purge old pfSense VMs
for i in {1..120}; do
    sshpass -p "totallynotabruteforce" ssh syadmin@10.42.32.7
done
