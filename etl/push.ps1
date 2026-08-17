# activate the venv and set the direcory
echo on
echo "Activating venv"
cd C:\users\tylerw\ChristensenCRM\etl
.\venv\Scripts\activate.ps1

echo "Running push_to_supabase.py"
python push_to_supabase.py

echo "Deactivating venv"
deactivate

echo "Done"
