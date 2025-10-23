# sistema_costura_funcional.rb
require 'sinatra'
require 'sqlite3'
require 'date'

class SistemaCostura < Sinatra::Base
  configure do
    set :public_folder, File.dirname(__FILE__)
    enable :sessions
    set :bind, '0.0.0.0'
    set :port, 4567
  end

  # Configuração do banco de dados
  def db
    return @db if @db
    @db = SQLite3::Database.new('costura.db')
    @db.results_as_hash = true
    @db.execute('PRAGMA foreign_keys = ON')
    @db
  end

  # Criar tabelas se não existirem
  before do
    criar_tabelas
  end

  def criar_tabelas
    # Tabela de clientes
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS clientes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone TEXT,
        email TEXT,
        endereco TEXT,
        data_cadastro DATE DEFAULT CURRENT_DATE,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL

    # Tabela de pedidos
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS pedidos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cliente_id INTEGER,
        descricao TEXT NOT NULL,
        tipo_servico TEXT NOT NULL,
        preco REAL NOT NULL,
        data_pedido DATE DEFAULT CURRENT_DATE,
        data_entrega DATE,
        observacoes TEXT,
        status TEXT DEFAULT 'pendente',
        pago BOOLEAN DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (cliente_id) REFERENCES clientes (id)
      )
    SQL

    # Tabela de despesas
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS despesas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        descricao TEXT NOT NULL,
        valor REAL NOT NULL,
        categoria TEXT NOT NULL,
        data DATE NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL
  end

  # Helpers
  helpers do
    def formatar_data(data_str)
      return '' unless data_str
      Date.parse(data_str).strftime('%d/%m/%Y')
    rescue
      data_str.to_s
    end

    def formatar_moeda(valor)
      "R$ #{'%.2f' % valor.to_f}".gsub('.', ',')
    end

    def status_emoji(status)
      {
        'pendente' => '⏳',
        'andamento' => '🔄', 
        'concluido' => '✅',
        'entregue' => '🎉'
      }[status.to_s] || '📝'
    end

    def calcular_estatisticas
      # Total de clientes
      total_clientes = db.get_first_value("SELECT COUNT(*) FROM clientes").to_i
      
      # Total de pedidos
      total_pedidos = db.get_first_value("SELECT COUNT(*) FROM pedidos").to_i
      
      # Pedidos ativos
      pedidos_ativos = db.get_first_value("SELECT COUNT(*) FROM pedidos WHERE status != 'entregue'").to_i
      
      # Total de receitas
      total_receitas = db.get_first_value("SELECT COALESCE(SUM(preco), 0) FROM pedidos WHERE pago = 1").to_f
      
      # Total de despesas
      total_despesas = db.get_first_value("SELECT COALESCE(SUM(valor), 0) FROM despesas").to_f
      
      {
        total_clientes: total_clientes,
        total_pedidos: total_pedidos,
        pedidos_ativos: pedidos_ativos,
        total_receitas: total_receitas,
        total_despesas: total_despesas,
        lucro: total_receitas - total_despesas
      }
    end

    def alerta(tipo, mensagem)
      session[:alert] = { type: tipo, message: mensagem }
    end
  end

  # Middleware para alertas
  before do
    @alert = session.delete(:alert)
  end

  # ========== ROTAS ==========

  # Página inicial
  get '/' do
    stats = calcular_estatisticas
    
    # Pedidos recentes
    @pedidos_recentes = db.execute("
      SELECT p.*, c.nome as cliente_nome 
      FROM pedidos p 
      LEFT JOIN clientes c ON p.cliente_id = c.id 
      ORDER BY p.created_at DESC 
      LIMIT 5
    ")
    
    erb :index, locals: { stats: stats }
  end

  # ========== CLIENTES ==========

  get '/clientes' do
    @clientes = db.execute("SELECT * FROM clientes ORDER BY nome")
    erb :clientes
  end

  post '/clientes/novo' do
    nome = params[:nome]&.strip
    telefone = params[:telefone]&.strip
    email = params[:email]&.strip
    endereco = params[:endereco]&.strip

    if nome.empty?
      alerta('error', 'Nome do cliente é obrigatório!')
      redirect '/clientes'
    end

    db.execute(
      "INSERT INTO clientes (nome, telefone, email, endereco) VALUES (?, ?, ?, ?)",
      [nome, telefone, email, endereco]
    )
    
    alerta('success', 'Cliente cadastrado com sucesso!')
    redirect '/clientes'
  end

  get '/clientes/:id' do
    cliente_id = params[:id].to_i
    
    @cliente = db.execute("SELECT * FROM clientes WHERE id = ?", cliente_id).first
    unless @cliente
      alerta('error', 'Cliente não encontrado!')
      redirect '/clientes'
    end

    @pedidos_cliente = db.execute("
      SELECT * FROM pedidos 
      WHERE cliente_id = ? 
      ORDER BY created_at DESC
    ", cliente_id)

    erb :cliente_detalhes
  end

  # ========== PEDIDOS ==========

  get '/pedidos' do
    @pedidos = db.execute("
      SELECT p.*, c.nome as cliente_nome 
      FROM pedidos p 
      LEFT JOIN clientes c ON p.cliente_id = c.id 
      ORDER BY p.created_at DESC
    ")
    erb :pedidos
  end

  get '/pedidos/novo' do
    @clientes = db.execute("SELECT * FROM clientes ORDER BY nome")
    erb :novo_pedido
  end

  post '/pedidos/novo' do
    cliente_id = params[:cliente_id].to_i
    descricao = params[:descricao]&.strip
    tipo_servico = params[:tipo_servico]&.strip
    preco = params[:preco].to_f
    data_entrega = params[:data_entrega]
    observacoes = params[:observacoes]&.strip

    if cliente_id == 0 || descricao.empty? || tipo_servico.empty? || preco <= 0
      alerta('error', 'Preencha todos os campos obrigatórios!')
      redirect '/pedidos/novo'
    end

    db.execute(
      "INSERT INTO pedidos (cliente_id, descricao, tipo_servico, preco, data_entrega, observacoes) VALUES (?, ?, ?, ?, ?, ?)",
      [cliente_id, descricao, tipo_servico, preco, data_entrega, observacoes]
    )
    
    alerta('success', 'Pedido criado com sucesso!')
    redirect '/pedidos'
  end

  post '/pedidos/:id/status' do
    pedido_id = params[:id].to_i
    novo_status = params[:novo_status]
    
    db.execute(
      "UPDATE pedidos SET status = ? WHERE id = ?",
      [novo_status, pedido_id]
    )
    
    alerta('success', "Status atualizado para: #{novo_status}")
    redirect '/pedidos'
  end

  post '/pedidos/:id/pagamento' do
    pedido_id = params[:id].to_i
    pago = params[:pago] == 'true'
    
    db.execute(
      "UPDATE pedidos SET pago = ? WHERE id = ?",
      [pago ? 1 : 0, pedido_id]
    )
    
    status = pago ? 'pago' : 'pendente'
    alerta('success', "Pagamento marcado como #{status}")
    redirect '/pedidos'
  end

  # ========== DESPESAS ==========

  get '/despesas' do
    @despesas = db.execute("SELECT * FROM despesas ORDER BY data DESC")
    @total_despesas = @despesas.sum { |d| d['valor'].to_f }
    erb :despesas
  end

  post '/despesas/nova' do
    descricao = params[:descricao]&.strip
    valor = params[:valor].to_f
    categoria = params[:categoria]
    data = params[:data]

    if descricao.empty? || valor <= 0 || categoria.empty?
      alerta('error', 'Preencha todos os campos obrigatórios!')
      redirect '/despesas'
    end

    db.execute(
      "INSERT INTO despesas (descricao, valor, categoria, data) VALUES (?, ?, ?, ?)",
      [descricao, valor, categoria, data]
    )
    
    alerta('success', 'Despesa registrada com sucesso!')
    redirect '/despesas'
  end

  post '/despesas/:id/excluir' do
    despesa_id = params[:id].to_i
    db.execute("DELETE FROM despesas WHERE id = ?", despesa_id)
    alerta('success', 'Despesa excluída com sucesso!')
    redirect '/despesas'
  end

  # ========== FINANCEIRO ==========

  get '/financeiro' do
    stats = calcular_estatisticas
    erb :financeiro, locals: { stats: stats }
  end

  # ========== RELATÓRIOS ==========

  get '/relatorios' do
    @clientes = db.execute("SELECT * FROM clientes")
    @pedidos = db.execute("SELECT * FROM pedidos")
    @despesas = db.execute("SELECT * FROM despesas")
    erb :relatorios
  end

  # ========== TEMPLATES ==========

  # Layout principal
  template :layout do
    <<~HTML
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Sistema Costura</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { 
                font-family: Arial, sans-serif; 
                background: #f5f5f5;
                color: #333;
            }
            .container { 
                max-width: 1200px; 
                margin: 0 auto; 
                padding: 20px; 
            }
            .header { 
                background: #4CAF50; 
                color: white; 
                padding: 20px; 
                border-radius: 10px;
                margin-bottom: 20px;
                text-align: center;
            }
            .nav { 
                background: white; 
                padding: 15px; 
                border-radius: 10px;
                margin-bottom: 20px;
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
            }
            .nav a { 
                text-decoration: none; 
                color: #333;
                padding: 10px 15px;
                border-radius: 5px;
                transition: background 0.3s;
            }
            .nav a:hover { 
                background: #f0f0f0; 
            }
            .card { 
                background: white; 
                padding: 20px; 
                border-radius: 10px; 
                margin-bottom: 20px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            .btn { 
                background: #4CAF50; 
                color: white; 
                padding: 10px 15px; 
                border: none; 
                border-radius: 5px; 
                cursor: pointer; 
                text-decoration: none;
                display: inline-block;
            }
            .btn:hover { 
                background: #45a049; 
            }
            .btn-danger { background: #dc3545; }
            .btn-danger:hover { background: #c82333; }
            .stats-grid { 
                display: grid; 
                grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); 
                gap: 20px; 
                margin-bottom: 20px;
            }
            .stat-card { 
                background: white; 
                padding: 20px; 
                border-radius: 10px; 
                text-align: center;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            .stat-number { 
                font-size: 2em; 
                font-weight: bold; 
                margin: 10px 0;
            }
            table { 
                width: 100%; 
                border-collapse: collapse; 
                background: white;
                border-radius: 10px;
                overflow: hidden;
            }
            th, td { 
                padding: 12px 15px; 
                text-align: left; 
                border-bottom: 1px solid #ddd;
            }
            th { 
                background: #f8f9fa; 
                font-weight: bold;
            }
            tr:hover { background: #f8f9fa; }
            .form-group { margin-bottom: 15px; }
            label { display: block; margin-bottom: 5px; font-weight: bold; }
            input, select, textarea { 
                width: 100%; 
                padding: 10px; 
                border: 1px solid #ddd; 
                border-radius: 5px; 
            }
            .alert { 
                padding: 15px; 
                border-radius: 5px; 
                margin-bottom: 20px;
            }
            .alert-success { background: #d4edda; color: #155724; }
            .alert-error { background: #f8d7da; color: #721c24; }
            .badge { 
                padding: 4px 8px; 
                border-radius: 3px; 
                font-size: 0.8em;
            }
            .badge-success { background: #28a745; color: white; }
            .badge-warning { background: #ffc107; color: black; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>🧵 Sistema Costura</h1>
                <p>Gestão para Costureira</p>
            </div>
            
            <div class="nav">
                <a href="/">🏠 Início</a>
                <a href="/clientes">👥 Clientes</a>
                <a href="/pedidos">📋 Pedidos</a>
                <a href="/financeiro">💰 Financeiro</a>
                <a href="/despesas">💸 Despesas</a>
                <a href="/relatorios">📊 Relatórios</a>
            </div>

            <% if @alert %>
                <div class="alert alert-<%= @alert[:type] %>">
                    <%= @alert[:message] %>
                </div>
            <% end %>

            <%= yield %>
        </div>
    </body>
    </html>
    HTML
  end

  # Página inicial
  template :index do
    <<~HTML
    <% stats = locals[:stats] %>
    
    <div class="stats-grid">
        <div class="stat-card">
            <h3>Total de Clientes</h3>
            <div class="stat-number"><%= stats[:total_clientes] %></div>
        </div>
        
        <div class="stat-card">
            <h3>Pedidos Ativos</h3>
            <div class="stat-number"><%= stats[:pedidos_ativos] %></div>
        </div>
        
        <div class="stat-card">
            <h3>Receitas</h3>
            <div class="stat-number"><%= formatar_moeda(stats[:total_receitas]) %></div>
        </div>
        
        <div class="stat-card">
            <h3>Lucro</h3>
            <div class="stat-number"><%= formatar_moeda(stats[:lucro]) %></div>
        </div>
    </div>

    <div class="card">
        <h2>Pedidos Recentes</h2>
        <% if @pedidos_recentes.any? %>
            <table>
                <thead>
                    <tr>
                        <th>Cliente</th>
                        <th>Serviço</th>
                        <th>Valor</th>
                        <th>Status</th>
                        <th>Entrega</th>
                    </tr>
                </thead>
                <tbody>
                    <% @pedidos_recentes.each do |pedido| %>
                        <tr>
                            <td><%= pedido['cliente_nome'] %></td>
                            <td><%= pedido['tipo_servico'] %></td>
                            <td><%= formatar_moeda(pedido['preco']) %></td>
                            <td>
                                <%= status_emoji(pedido['status']) %> 
                                <%= pedido['status'] %>
                            </td>
                            <td><%= formatar_data(pedido['data_entrega']) %></td>
                        </tr>
                    <% end %>
                </tbody>
            </table>
        <% else %>
            <p>Nenhum pedido cadastrado ainda.</p>
        <% end %>
        
        <div style="margin-top: 20px;">
            <a href="/pedidos/novo" class="btn">➕ Novo Pedido</a>
        </div>
    </div>
    HTML
  end

  # Clientes
  template :clientes do
    <<~HTML
    <div class="card">
        <h2>👥 Clientes</h2>
        
        <form action="/clientes/novo" method="post" style="background: #f8f9fa; padding: 20px; border-radius: 10px; margin-bottom: 20px;">
            <h3>Cadastrar Novo Cliente</h3>
            <div class="form-group">
                <label>Nome:</label>
                <input type="text" name="nome" required>
            </div>
            <div class="form-group">
                <label>Telefone:</label>
                <input type="text" name="telefone" required>
            </div>
            <div class="form-group">
                <label>Email:</label>
                <input type="email" name="email">
            </div>
            <div class="form-group">
                <label>Endereço:</label>
                <textarea name="endereco"></textarea>
            </div>
            <button type="submit" class="btn">Salvar Cliente</button>
        </form>

        <h3>Lista de Clientes</h3>
        <% if @clientes.any? %>
            <table>
                <thead>
                    <tr>
                        <th>Nome</th>
                        <th>Telefone</th>
                        <th>Email</th>
                        <th>Cadastro</th>
                        <th>Ações</th>
                    </tr>
                </thead>
                <tbody>
                    <% @clientes.each do |cliente| %>
                        <tr>
                            <td><strong><%= cliente['nome'] %></strong></td>
                            <td><%= cliente['telefone'] %></td>
                            <td><%= cliente['email'] || '-' %></td>
                            <td><%= formatar_data(cliente['data_cadastro']) %></td>
                            <td>
                                <a href="/clientes/<%= cliente['id'] %>" class="btn">Ver</a>
                            </td>
                        </tr>
                    <% end %>
                </tbody>
            </table>
        <% else %>
            <p>Nenhum cliente cadastrado ainda.</p>
        <% end %>
    </div>
    HTML
  end

  # Detalhes do cliente
  template :cliente_detalhes do
    <<~HTML
    <div class="card">
        <h2>Detalhes do Cliente</h2>
        
        <% if @cliente %>
            <div style="background: #f8f9fa; padding: 20px; border-radius: 10px; margin-bottom: 20px;">
                <h3><%= @cliente['nome'] %></h3>
                <p><strong>Telefone:</strong> <%= @cliente['telefone'] %></p>
                <p><strong>Email:</strong> <%= @cliente['email'] || 'Não informado' %></p>
                <p><strong>Endereço:</strong> <%= @cliente['endereco'] || 'Não informado' %></p>
                <p><strong>Cadastrado em:</strong> <%= formatar_data(@cliente['data_cadastro']) %></p>
            </div>

            <h3>Pedidos do Cliente</h3>
            <% if @pedidos_cliente.any? %>
                <table>
                    <thead>
                        <tr>
                            <th>Serviço</th>
                            <th>Valor</th>
                            <th>Status</th>
                            <th>Entrega</th>
                        </tr>
                    </thead>
                    <tbody>
                        <% @pedidos_cliente.each do |pedido| %>
                            <tr>
                                <td>
                                    <strong><%= pedido['tipo_servico'] %></strong>
                                    <br><small><%= pedido['descricao'] %></small>
                                </td>
                                <td><%= formatar_moeda(pedido['preco']) %></td>
                                <td>
                                    <%= status_emoji(pedido['status']) %> 
                                    <%= pedido['status'] %>
                                </td>
                                <td><%= formatar_data(pedido['data_entrega']) %></td>
                            </tr>
                        <% end %>
                    </tbody>
                </table>
            <% else %>
                <p>Este cliente ainda não fez nenhum pedido.</p>
                <a href="/pedidos/novo" class="btn">Criar Pedido</a>
            <% end %>
            
            <div style="margin-top: 20px;">
                <a href="/clientes" class="btn">← Voltar</a>
            </div>
        <% else %>
            <p>Cliente não encontrado.</p>
            <a href="/clientes" class="btn">← Voltar</a>
        <% end %>
    </div>
    HTML
  end

  # Pedidos
  template :pedidos do
    <<~HTML
    <div class="card">
        <h2>📋 Pedidos</h2>
        
        <div style="margin-bottom: 20px;">
            <a href="/pedidos/novo" class="btn">➕ Novo Pedido</a>
        </div>

        <% if @pedidos.any? %>
            <table>
                <thead>
                    <tr>
                        <th>Cliente</th>
                        <th>Serviço</th>
                        <th>Valor</th>
                        <th>Status</th>
                        <th>Entrega</th>
                        <th>Pagamento</th>
                        <th>Ações</th>
                    </tr>
                </thead>
                <tbody>
                    <% @pedidos.each do |pedido| %>
                        <tr>
                            <td><%= pedido['cliente_nome'] %></td>
                            <td>
                                <div><strong><%= pedido['tipo_servico'] %></strong></div>
                                <small><%= pedido['descricao'] %></small>
                            </td>
                            <td><%= formatar_moeda(pedido['preco']) %></td>
                            <td>
                                <form action="/pedidos/<%= pedido['id'] %>/status" method="post" style="display: inline;">
                                    <select name="novo_status" onchange="this.form.submit()">
                                        <option value="pendente" <%= 'selected' if pedido['status'] == 'pendente' %>>Pendente</option>
                                        <option value="andamento" <%= 'selected' if pedido['status'] == 'andamento' %>>Andamento</option>
                                        <option value="concluido" <%= 'selected' if pedido['status'] == 'concluido' %>>Concluído</option>
                                        <option value="entregue" <%= 'selected' if pedido['status'] == 'entregue' %>>Entregue</option>
                                    </select>
                                </form>
                            </td>
                            <td><%= formatar_data(pedido['data_entrega']) %></td>
                            <td>
                                <% if pedido['status'] == 'entregue' %>
                                    <% if pedido['pago'] == 1 %>
                                        <span class="badge badge-success">Pago</span>
                                    <% else %>
                                        <span class="badge badge-warning">Pendente</span>
                                        <form action="/pedidos/<%= pedido['id'] %>/pagamento" method="post" style="display: inline;">
                                            <input type="hidden" name="pago" value="true">
                                            <button type="submit" class="btn" style="padding: 2px 5px;">✅</button>
                                        </form>
                                    <% end %>
                                <% else %>
                                    -
                                <% end %>
                            </td>
                            <td>
                                <% if pedido['pago'] == 1 %>
                                    <form action="/pedidos/<%= pedido['id'] %>/pagamento" method="post">
                                        <input type="hidden" name="pago" value="false">
                                        <button type="submit" class="btn btn-danger" style="padding: 5px 10px;">Estornar</button>
                                    </form>
                                <% end %>
                            </td>
                        </tr>
                    <% end %>
                </tbody>
            </table>
        <% else %>
            <p>Nenhum pedido cadastrado ainda.</p>
        <% end %>
    </div>
    HTML
  end

  # Novo pedido
  template :novo_pedido do
    <<~HTML
    <div class="card">
        <h2>Novo Pedido</h2>
        
        <form action="/pedidos/novo" method="post">
            <div class="form-group">
                <label>Cliente:</label>
                <select name="cliente_id" required>
                    <option value="">Selecione um cliente</option>
                    <% @clientes.each do |cliente| %>
                        <option value="<%= cliente['id'] %>">
                            <%= cliente['nome'] %> - <%= cliente['telefone'] %>
                        </option>
                    <% end %>
                </select>
            </div>
            
            <div class="form-group">
                <label>Tipo de Serviço:</label>
                <input type="text" name="tipo_servico" required>
            </div>
            
            <div class="form-group">
                <label>Descrição:</label>
                <textarea name="descricao" required></textarea>
            </div>
            
            <div class="form-group">
                <label>Preço (R$):</label>
                <input type="number" name="preco" step="0.01" required>
            </div>
            
            <div class="form-group">
                <label>Data de Entrega:</label>
                <input type="date" name="data_entrega" required>
            </div>
            
            <div class="form-group">
                <label>Observações:</label>
                <textarea name="observacoes"></textarea>
            </div>
            
            <button type="submit" class="btn">Criar Pedido</button>
            <a href="/pedidos" class="btn">Cancelar</a>
        </form>
    </div>
    HTML
  end

  # Despesas
  template :despesas do
    <<~HTML
    <div class="card">
        <h2>💸 Despesas</h2>
        
        <form action="/despesas/nova" method="post" style="background: #f8f9fa; padding: 20px; border-radius: 10px; margin-bottom: 20px;">
            <h3>Nova Despesa</h3>
            <div class="form-group">
                <label>Descrição:</label>
                <input type="text" name="descricao" required>
            </div>
            
            <div class="form-group">
                <label>Valor (R$):</label>
                <input type="number" name="valor" step="0.01" required>
            </div>
            
            <div class="form-group">
                <label>Categoria:</label>
                <select name="categoria" required>
                    <option value="material">Material</option>
                    <option value="conta">Conta</option>
                    <option value="transporte">Transporte</option>
                    <option value="outros">Outros</option>
                </select>
            </div>
            
            <div class="form-group">
                <label>Data:</label>
                <input type="date" name="data" value="<%= Date.today.strftime('%Y-%m-%d') %>" required>
            </div>
            
            <button type="submit" class="btn">Salvar Despesa</button>
        </form>

        <h3>Histórico de Despesas</h3>
        <% if @despesas.any? %>
            <table>
                <thead>
                    <tr>
                        <th>Data</th>
                        <th>Descrição</th>
                        <th>Categoria</th>
                        <th>Valor</th>
                        <th>Ações</th>
                    </tr>
                </thead>
                <tbody>
                    <% @despesas.each do |despesa| %>
                        <tr>
                            <td><%= formatar_data(despesa['data']) %></td>
                            <td><%= despesa['descricao'] %></td>
                            <td><%= despesa['categoria'] %></td>
                            <td style="color: #dc3545;"><strong><%= formatar_moeda(despesa['valor']) %></strong></td>
                            <td>
                                <form action="/despesas/<%= despesa['id'] %>/excluir" method="post" 
                                      onsubmit="return confirm('Tem certeza que deseja excluir esta despesa?')"
                                      style="display: inline;">
                                    <button type="submit" class="btn btn-danger">Excluir</button>
                                </form>
                            </td>
                        </tr>
                    <% end %>
                </tbody>
            </table>
            
            <div style="margin-top: 20px; padding: 15px; background: #ffebee; border-radius: 5px; text-align: center;">
                <strong>Total de Despesas: <%= formatar_moeda(@total_despesas) %></strong>
            </div>
        <% else %>
            <p>Nenhuma despesa registrada ainda.</p>
        <% end %>
    </div>
    HTML
  end

  # Financeiro
  template :financeiro do
    <<~HTML
    <% stats = locals[:stats] %>
    
    <div class="stats-grid">
        <div class="stat-card">
            <h3>Total de Receitas</h3>
            <div class="stat-number" style="color: #28a745;"><%= formatar_moeda(stats[:total_receitas]) %></div>
        </div>
        
        <div class="stat-card">
            <h3>Total de Despesas</h3>
            <div class="stat-number" style="color: #dc3545;"><%= formatar_moeda(stats[:total_despesas]) %></div>
        </div>
        
        <div class="stat-card">
            <h3>Lucro Líquido</h3>
            <div class="stat-number" style="color: <%= stats[:lucro] >= 0 ? '#28a745' : '#dc3545' %>;">
                <%= formatar_moeda(stats[:lucro]) %>
            </div>
        </div>
    </div>

    <div class="card">
        <h2>Resumo Financeiro</h2>
        
        <div style="background: #f8f9fa; padding: 20px; border-radius: 10px;">
            <p><strong>Margem de Lucro:</strong> 
                <% if stats[:total_receitas] > 0 %>
                    <%= '%.1f' % ((stats[:lucro] / stats[:total_receitas]) * 100) %>%
                <% else %>
                    0%
                <% end %>
            </p>
            
            <div style="margin-top: 15px;">
                <a href="/despesas" class="btn">Gerenciar Despesas</a>
                <a href="/pedidos" class="btn">Ver Pedidos</a>
            </div>
        </div>
    </div>
    HTML
  end

  # Relatórios
  template :relatorios do
    <<~HTML
    <div class="card">
        <h2>📊 Relatórios</h2>
        
        <div class="stats-grid">
            <div class="stat-card">
                <h3>Total de Clientes</h3>
                <div class="stat-number"><%= @clientes.size %></div>
            </div>
            
            <div class="stat-card">
                <h3>Total de Pedidos</h3>
                <div class="stat-number"><%= @pedidos.size %></div>
            </div>
            
            <div class="stat-card">
                <h3>Total de Despesas</h3>
                <div class="stat-number"><%= formatar_moeda(@despesas.sum { |d| d['valor'].to_f }) %></div>
            </div>
        </div>

        <h3>Status dos Pedidos</h3>
        <% status_count = @pedidos.group_by { |p| p['status'] } %>
        <ul>
            <% status_count.each do |status, pedidos| %>
                <li>
                    <%= status_emoji(status) %> <%= status.capitalize %>: 
                    <strong><%= pedidos.size %></strong> pedidos
                </li>
            <% end %>
        </ul>
    </div>
    HTML
  end

end

# Iniciar servidor
if __FILE__ == $0
  puts "=" * 50
  puts "🧵 SISTEMA COSTURA - INICIANDO"
  puts "=" * 50
  puts "📱 Acesse: http://localhost:4567"
  puts "💾 Banco de dados: costura.db"
  puts "🛑 Para parar: Ctrl+C"
  puts "=" * 50
  
  SistemaCostura.run!
end