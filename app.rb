# app.rb
require 'sinatra'
require 'json'
require 'date'

class App < Sinatra::Base
  set :public_folder, File.dirname(__FILE__) + '/public'
  
  # Arquivos de dados
  CLIENTES_FILE = 'clientes.json'
  PEDIDOS_FILE = 'pedidos.json'
  DESPESAS_FILE = 'despesas.json'

  # Helper methods
  def carregar_dados(arquivo)
    if File.exist?(arquivo)
      JSON.parse(File.read(arquivo), symbolize_names: true)
    else
      []
    end
  end

  def salvar_dados(arquivo, dados)
    File.write(arquivo, JSON.pretty_generate(dados))
  end

  # Rotas
  get '/' do
    @clientes = carregar_dados(CLIENTES_FILE)
    @pedidos = carregar_dados(PEDIDOS_FILE)
    @despesas = carregar_dados(DESPESAS_FILE)
    
    erb :index
  end

  # Clientes
  get '/clientes' do
    @clientes = carregar_dados(CLIENTES_FILE)
    erb :clientes
  end

  post '/clientes/novo' do
    clientes = carregar_dados(CLIENTES_FILE)
    
    novo_cliente = {
      id: Time.now.to_i,
      nome: params[:nome],
      telefone: params[:telefone],
      email: params[:email],
      endereco: params[:endereco],
      data_cadastro: Date.today.to_s
    }

    clientes << novo_cliente
    salvar_dados(CLIENTES_FILE, clientes)
    
    redirect '/clientes'
  end

  # Pedidos
  get '/pedidos' do
    @pedidos = carregar_dados(PEDIDOS_FILE)
    erb :pedidos
  end

  get '/pedidos/novo' do
    @clientes = carregar_dados(CLIENTES_FILE)
    erb :novo_pedido
  end

  post '/pedidos/novo' do
    pedidos = carregar_dados(PEDIDOS_FILE)
    clientes = carregar_dados(CLIENTES_FILE)
    
    cliente = clientes.find { |c| c[:id] == params[:cliente_id].to_i }

    if cliente
      novo_pedido = {
        id: Time.now.to_i,
        cliente_id: params[:cliente_id].to_i,
        cliente_nome: cliente[:nome],
        descricao: params[:descricao],
        tipo_servico: params[:tipo_servico],
        preco: params[:preco].to_f,
        data_pedido: Date.today.to_s,
        data_entrega: params[:data_entrega],
        observacoes: params[:observacoes],
        status: "pendente",
        pago: false
      }

      pedidos << novo_pedido
      salvar_dados(PEDIDOS_FILE, pedidos)
    end
    
    redirect '/pedidos'
  end

  post '/pedidos/:id/status' do
    pedidos = carregar_dados(PEDIDOS_FILE)
    pedido = pedidos.find { |p| p[:id] == params[:id].to_i }
    
    if pedido
      pedido[:status] = params[:novo_status]
      salvar_dados(PEDIDOS_FILE, pedidos)
    end
    
    redirect '/pedidos'
  end

  # Financeiro
  get '/financeiro' do
    pedidos = carregar_dados(PEDIDOS_FILE)
    despesas = carregar_dados(DESPESAS_FILE)
    
    @total_receitas = pedidos.select { |p| p[:pago] }.sum { |p| p[:preco].to_f }
    @total_despesas = despesas.sum { |d| d[:valor].to_f }
    @lucro = @total_receitas - @total_despesas
    
    erb :financeiro
  end

  get '/despesas' do
    @despesas = carregar_dados(DESPESAS_FILE)
    erb :despesas
  end

  post '/despesas/nova' do
    despesas = carregar_dados(DESPESAS_FILE)
    
    nova_despesa = {
      id: Time.now.to_i,
      descricao: params[:descricao],
      valor: params[:valor].to_f,
      categoria: params[:categoria],
      data: params[:data]
    }

    despesas << nova_despesa
    salvar_dados(DESPESAS_FILE, despesas)
    
    redirect '/despesas'
  end
end

# Iniciar servidor
if __FILE__ == $0
  puts "🚀 Servidor Costura Web iniciando..."
  puts "📱 Acesse: http://localhost:4567"
  App.run!
end