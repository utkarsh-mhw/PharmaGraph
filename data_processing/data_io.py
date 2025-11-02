import pandas as pd
import os

def read_file(path_to_csv):
    df = pd.read_csv(path_to_csv)
    return df
