defmodule DungeonsanddragonsWeb.PageController do
  use DungeonsanddragonsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
