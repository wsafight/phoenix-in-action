defmodule Auction.Password do
  def hash(password), do: Pbkdf2.hash_pwd_salt(password)

  def verify_with_hash(password, hash), do: Pbkdf2.verify_pass(password, hash)

  def dummy_verify, do: Pbkdf2.no_user_verify()
end
